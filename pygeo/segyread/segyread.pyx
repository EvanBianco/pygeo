#!/usr/bin/env python

# pygeo - a distribution of tools for managing geophysical data
# Copyright (C) 2011, 2012 Brendan Smithyman

# This file is part of pygeo.

# pygeo is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation, either version 3 of
# the License, or (at your option) any later version.

# pygeo is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.

# You should have received a copy of the GNU Lesser General Public License
# along with pygeo.  If not, see <http://www.gnu.org/licenses/>.

# ----------------------------------------------------------------------

import os.path as _path
import mmap as _mmap
import struct as _struct
import sys as _sys

import numpy as _np
cimport numpy as _np
import cython 
cimport cython

MEGABYTE = 1048576


BHEADLIST = ['jobid','lino','reno','ntrpr','nart','hdt','dto','hns','nso',
             'format','fold','tsort','vscode','hsfs','hsfe','hslen','hstyp',
             'schn','hstas','hstae','htatyp','hcorr','bgrcv','rcvm','mfeet',
             'polyt','vpol']

TRHEADLIST = ['tracl','tracr','fldr','tracf','ep','cdp','cdpt','trid','nvs',
             'nhs','duse','offset','gelev','selev','sdepth','gdel','sdel',
             'swdep','gwdep','scalel','scalco','sx','sy','gx','gy','counit',
             'wevel','swevel','sut','gut','sstat','gstat','tstat','laga',
             'lagb','delrt','muts','mute','ns','dt','gain','igc','igi','corr',
             'sfs','sfe','slen','styp','stas','stae','tatyp','afilf','afils',
             'nofilf','nofils','lcf','hcf','lcs','hcs','year','day','hour','minute','sec',
             'timbas','trwf','grnors','grnofr','grnlof','gaps','otrav']

BHEADSTRUCT = '>3L24H'
TRHEADSTRUCT = '>7L4H8L2h4L46H'

MAJORHEADERS = [1,2,3,4,7,38,39]

class SEGYFileException(Exception):
  '''
  Catch-all exception class for SEGYFile.
  '''

  def __init__ (self, value):
    self.parameter = value

  def __str__ (self):
    return repr(self.parameter)

class SEGYTraceHeader (object):
  '''
  Provides read access to trace headers from an existing :py:class:`SEGYFile` instance.
  
  :param sf: Parent class to attach to.
  :param sf: :py:class:`SEGYFile`

  :returns: :py:class:`SEGYTraceHeader` instance
  '''

  class STHIter (object):
    def __init__ (self, sth):
      self.sth = sth
      self.stop = len(sth)
      self.index = 0

    def next (self):
      if (self.index >= self.stop):
        raise StopIteration

      else:
        result = self.sth.__getitem__(self.index)
        self.index += 1
        return result

  def __iter__ (self):
    return self.STHIter(self)

  def __init__ (self, sf):
    self.sf = sf

  def __len__ (self):
    return self.sf.ntr

  def __getitem__ (self, index):
    '''
    Returns dictionary (or list of dictionaries) that maps header information
    for each defined SEG-Y trace header.  SU style names, see TRHEADLIST.

    :param index: Slice object or trace number (using zero-based numbering).
    :type traces: slice object

    :returns: dict, list
    '''

    if isinstance(index, slice):
      indices = index.indices(self.sf.ntr)
      return [self.__getitem__(i) for i in xrange(*indices)]

    sf = self.sf
    curloc = sf._fp.tell()
    sf._fp.seek(sf._calcHeadOffset(index+1, sf.ns))

    traceheader = sf._fp.read(180)

    traceheader = _struct.unpack(TRHEADSTRUCT,traceheader)
    tracehead = {}

    for i, label in enumerate(TRHEADLIST):
      tracehead[label] = traceheader[i]

    sf._fp.seek(curloc)

    return tracehead

class SEGYFile (object):
  '''
  Provides read access to a SEG-Y dataset (headers and data).

  :param filename: The system path of the SEG-Y file to open.
  :type filename: str
  :param verbose: Controls whether diagnostic information is printed.  This includes status messages when endian and format conversions are made, and may be useful in diagnosing problems.
  :type verbose: bool
  :param majorheadersonly: Only read certain specific headers (legacy).  No longer relevant, but may be expected by some old programs.
  :type majorheadersonly: bool
  :param isSU: Controls whether SEGYFile treats the datafile as a Seismic Unix variant SEG-Y file.  This overrides assumptions for endianness and format, and presumes the absence of the 3200-byte text header and 400-byte binary header.
  :type isSU: bool
  :param endian: Allows specification of file endianness [Foreign,Native,Little,Big].  By default this is auto-detected using a heuristic method, but it will fail for e.g., SEG-Y files that contain all zeros, or very noisy data.
  :type endian: str
  :param usemmap: Controls whether memory-mapped I/O is used. Default True.  In most (all?) cases this should be more efficient, and will be disabled automatically if not supported.
  :type usemmap: bool

  :returns: SEGYFile instance

  :var thead: *str* -- contains an ASCII-encoded translation of the EBCDIC 3200-byte tape header. 
  :var bhead: *dict* -- contains key:value pairs describing the data in the 400-byte binary reel header.
  :var trhead: :py:class:`SEGYTraceHeader` instance -- acts like a list of all the trace headers.  Individual items each return a dictionary that contains key:value pairs describing the data in the trace header.
  :var endian: *str* -- describing the endian of the datafile.
  :var mendian: *str* -- autodetected machine endian.
  :var ns: *int* -- number of samples in each trace.
  :var ntr: *int* -- number of traces in dataset.
  :var filesize: *int* -- size of datafile in bytes.
  :var ensembles: *dict* -- only exists if the experimental function :py:func:`SEGYFile._calcEnsembles` is called.  Maps shot gather numbers to trace numbers.  *Experimental*

  '''

  filename = None
  verbose = False
  majorheadersonly = True
  isSU = False
  endian = 'Auto'

  samplen = 4

  mendian = None
  usemmap = True
  thead = None
  bhead = None
  trhead = None
  ensembles = None
  initialized = False
  filesize = 0
  ns = 0
  ntr = 0

  # --------------------------------------------------------------------

  # Written by Robert Kern on the SciPy-user mailing list.
  def _ibm2ieee (self, ibm):
    """ Converts an IBM floating point number into IEEE format. """

    sign = ibm >> 31 & 0x01

    exponent = ibm >> 24 & 0x7f

    mantissa = ibm & 0x00ffffff
    mantissa = (mantissa * 1.0) / 2**24

    ieee = (1 - 2 * sign) * mantissa * 16.0**(exponent - 64)

    return ieee

  # --------------------------------------------------------------------

  def _detect_machine_endian (self):
    '''
    Detects native (machine) endian.
    '''

    if _struct.pack('h', 1) == '\x01\x00':
      endian = 'Little'
    else:
      endian = 'Big'

    return endian

  # --------------------------------------------------------------------

  def _isInitialized (self):
    return self.initialized

  # --------------------------------------------------------------------

  def _maybePrint (self, text):
    if self.verbose:
      _sys.stdout.write('%s\n'%(text,))
      _sys.stdout.flush()

  # --------------------------------------------------------------------

  def _readHeaders (self):

    '''
    Read SEG-Y headers.

    Returns 3 elements:

      1. Text header:   Returned as ASCII text, converted from IBM500 EBCIDIC.
      2. Block header:  Returned as a dictionary of values, named per SU style.
      3. Trace headers: Returned as a list of dictionaries, in trace order.
                        Dictionaries of values are named per SU style.
    '''

    self._maybePrint('Reading SEG-Y headers...')

    if (not self.isSU):
      textheader = self._fp.read(3200).replace(' ','\x25').decode('IBM500')
      blockheader = self._fp.read(400)

      blockheader = _struct.unpack(BHEADSTRUCT,blockheader[:60])
      bhead = {}

      for i, label in enumerate(BHEADLIST):
        bhead[label] = blockheader[i]

      if (bhead['hns'] != 0):
        self.ns = bhead['hns']
      else:
        traceheader = self._fp.read(240)
        traceheader = _struct.unpack(TRHEADSTRUCT,traceheader[:180])
        self.ns = traceheader[38]

    else:
      textheader = None
      bhead = None

      traceheader = self._fp.read(240)
      traceheader = _struct.unpack(TRHEADSTRUCT,traceheader[:180])
      self.ns = traceheader[38]

    self.thead = textheader
    self.bhead = bhead

    # Determine length of each sample from FORMAT code
    self._getSamplen()

    self.trhead = SEGYTraceHeader(self)

    self._maybePrint('Read SEG-Y headers.\n\t%d traces present.\n' % (self.ntr))

    return

  # --------------------------------------------------------------------

  def _calcHeadOffset (self, trace, ns):
    '''
    Calculates the byte offset of the beginning of the head portion of a
    seismic trace, given the trace number and the number of samples per.
    '''

    if (not self.isSU):
      return 3200 + 400 + (ns*self.samplen + 240)*(trace-1)
    else:
      return (ns*4 + 240)*(trace-1)

  def _calcDataOffset (self, trace, ns):
    '''
    Calculates the byte offset of the beginning of the data portion of a
    seismic trace, given the trace number and the number of samples per.
    '''

    return self._calcHeadOffset(trace, ns) + 240

  # --------------------------------------------------------------------

  def _detectEndian (self):
    if (self.endian != 'Auto'):
      self._maybePrint('%s endian specified... Not autodetecting.'%(self.endian,))
      if (self.endian != self.mendian):
        self._maybePrint('%s endian != %s endian, therefore Foreign.'%(self.endian,self.mendian))
        self.endian = 'Foreign'
    else:
      self._maybePrint('Auto endian specified... Trying to autodetect data endianness.')
      for i in xrange(1, self.ntr+1):
        locar = self.readTraces(i)
        if ((not abs(locar).sum() == 0.) and (not _np.isnan(locar.mean()))):
          nexp = abs(_np.frexp(locar.mean())[1])
          locar = locar.newbyteorder()
          fexp = abs(_np.frexp(locar.mean())[1])
          if (fexp > nexp):
            self.endian = 'Native'
          else:
            self.endian = 'Foreign'
          self._maybePrint('Scanned %d trace(s). Endian appears to be %s.'%(i, self.endian))
          break

      if (self.endian == 'Foreign'):
        self._maybePrint('Will attempt to convert to %s endian when traces are read.\n'%(self.mendian,))
      elif (self.endian == 'Auto'):
        self._maybePrint('Couldn\'t find any non-zero traces to test!\nAssuming Native endian.\n')


  # --------------------------------------------------------------------

  @cython.wraparound(False)
  @cython.boundscheck(False)
  def readTraces (self, traces=None):
    '''
    Returns trace data as a list of numpy arrays (i.e. non-adjacent trace
    numbers are allowed). Requires that traces be fixed length.

    :param traces: List of traces to return, using 1-based trace numbering.  Optional; if omitted, all traces are returned.
    :type traces: list, None

    :returns: ndarray -- 2D array containing (possibly non-adjacent) seismic traces

    .. versionchanged:: devel
    This is now a legacy interface, and is superseded by the __getitem__
    interface, which uses standard Python slice notation.
    '''

    if (traces == None):
      return self.__getitem__(slice(None))

    if not _np.iterable(traces):
      return self.__getitem__(traces-1)
    else:
      return _np.array([self.__getitem__(trace-1) for trace in traces], dtype=_np.float32)

  def __getitem__ (self, index):
    '''
    Returns traces from the open seismic dataset, with support for standard
    Python slice notation.  Trace numbers are zero-based.

    :param index: Slice object or trace number (using zero-based numbering).
    :type traces: slice object

    :returns: ndarray -- 2D array containing (possibly non-adjacent) seismic traces
    '''

    if isinstance(index, slice):
      indices = index.indices(len(self))
      traces = range(*indices)
    else:
      traces = [index]

    ns = self.ns

    result = []

    # Handles SU format and IEEE floating point
    if (self.isSU or self.bhead['format'] == 5):
      for trace in traces:
        self._fp.seek(self._calcDataOffset(trace+1, ns))
        tracetemp = self._fp.read(ns*4)
        result.append(_np.array(_struct.unpack('>%df'%(ns,), tracetemp), dtype=_np.float32))

    # Handles everything else
    else:
      if (self._isInitialized()):
        self._maybePrint('FORMAT == %d'%(self.bhead['format'],))

      # format == 1: IBM Floating Point
      if (self.bhead['format'] == 1):
        if (self._isInitialized()):
          self._maybePrint('             ...converting from IBM floating point.\n')
        for trace in traces:
          self._fp.seek(self._calcDataOffset(trace+1, ns))
          tracetemp = _struct.pack('%df'%(ns,),*[self._ibm2ieee(item) for item in _struct.unpack('>%dL'%(ns,),self._fp.read(ns*4))])
          result.append(_np.array(_struct.unpack('>%df'%(ns,), tracetemp), dtype=_np.float32))

      elif (self.bhead['format'] == 2):
        if (self._isInitialized()):
          self._maybePrint('             ...reading from 32-bit fixed point.\n')
        for trace in traces:
          self._fp.seek(self._calcDataOffset(trace+1, ns))
          result.append(_np.array(_struct.unpack('>%dl'%(ns,),self._fp.read(ns*4)), dtype=_np.int32))

      elif (self.bhead['format'] == 3):
        if (self._isInitialized()):
          self._maybePrint('             ...reading from 16-bit fixed point.\n')
        for trace in traces:
          self._fp.seek(self._calcDataOffset(trace+1, ns))
          result.append(_np.array(_struct.unpack('>%dh'%(ns,),self._fp.read(ns*2)), dtype=_np.int32))

      elif (self.bhead['format'] == 8):
        if (self._isInitialized()):
          self._maybePrint('             ...reading from 8-bit fixed point.\n')
        for trace in traces:
          self._fp.seek(self._calcDataOffset(trace+1, ns))
          result.append(_np.array(_struct.unpack('>%db'%(ns,),self._fp.read(ns)), dtype=_np.int32))

      elif (self.bhead['format'] == 4):
        if (self._isInitialized()):
          self._maybePrint('             ...converting from 32-bit fixed point w/ gain.\n')
        for trace in traces:
          self._fp.seek(self._calcDataOffset(trace+1, ns))
          tracemantissa = _np.array(_struct.unpack('>%s'%(ns*'xxh',), self._fp.read(ns)), dtype=_np.float32)
          traceexponent = _np.array(_struct.unpack('>%s'%(ns*'xbxx',), self._fp.read(ns)), dtype=_np.byte)
          result.append(tracemantissa**traceexponent)
      else:
        raise self.SEGYFileException('Unrecognized trace format.')

    
    result = _np.array(result, dtype=_np.float32)

    if (result.shape[0] == 1):
      result.shape = (result.shape[1],)

    if (self.endian == 'Foreign'):
      return result.byteswap()
    else:
      return result

  # --------------------------------------------------------------------

  def __repr__ (self):
    #return 'SEGYFile(%r, verbose=%r, isSU=%r, endian=%r)'%(self.filename,self.verbose,self.isSU,self.endian)
    return 'SEGYFile(%r)'%(self.filename,)

  # --------------------------------------------------------------------

  def findTraces (self, key, kmin, kmax):
    '''
    Finds traces whose header values fall within a particular range.  Trace numbers are 1-based, i.e., for use with readTraces.

    :param key: Key value of trace header to scan (uses lower-case SU names; see TRHEADLIST.
    :type key: str
    :param kmin: Minimum key value (inclusive).
    :type kmin: int
    :param kmax: Maximum key value (inclusive).
    :type kmax: int
    '''

    if not self.trhead[0].has_key(key):
      raise self.SEGYFileException('Invalid trace header: %s'%key)

    validtraces = []

    for i,trace in enumerate(self.trhead):
      if (trace[key] <= kmax and trace[key] >= kmin):
        validtraces.append(i+1)

    return validtraces

  # --------------------------------------------------------------------

  def _calcEnsembles (self):
    '''
    Prototype interface for calculating ensemble boundaries (currently hard-coded to find shot gathers).

    *Experimental*
    '''

    self.ensembles = {}

    self._maybePrint('Scanning ensembles...')
    for i in xrange(len(self)):
      fldr = self.trhead[i]['fldr']

      try:
        self.ensembles.keys().index(fldr)

      except ValueError:
        self.ensembles[fldr] = i

    self._maybePrint('Complete. Found %d ensemble(s).\n'%(len(self.ensembles),))
       
  # --------------------------------------------------------------------

  def __init__ (self, filename, verbose = None, majorheadersonly = None, isSU = None, endian = None, usemmap = None):

    self.filename = filename

    if (verbose is not None):
      self.verbose = verbose

    if (majorheadersonly is not None):
      self.majorheadersonly = majorheadersonly

    if (isSU is not None):
      self.isSU = isSU

    if (endian is not None):
      self.endian = endian

    if (usemmap is not None):
      self.usemmap = usemmap

    self._maybePrint('Detecting machine endianness...')
    self.mendian = self._detect_machine_endian()
    self._maybePrint('%s.\n'%(self.mendian,))

    self.filesize = _path.getsize(filename)

    fp = open(self.filename, 'r+b')
    if (self.usemmap):
      try:
        self._maybePrint('Trying to create memory map...')
        self._fp = _mmap.mmap(fp.fileno(), 0)
        self._maybePrint('Success. Using memory-mapped I/O.\n')
        fp.close()
      except:
        self._fp = fp
        self.usemmap = False
        self._maybePrint('Memory map failed; using conventional I/O.\n')
    else:
      self._fp = fp

    # Get header information from file
    self._readHeaders()

    # Determine length of each sample from FORMAT code
    #self._getSamplen()

    # Attempt to find shot-record boundaries
    #self._calcEnsembles()

    # Autodetect data endian
    self._detectEndian()

    # Confirm that the SEGYFile object has been initialized
    self.initialized = True
  
  # --------------------------------------------------------------------

  def __del__ (self):
    if self.usemmap:
      self._map.close()
    self._fp.close()

  # --------------------------------------------------------------------

  def _getSamplen (self):
    if (self.isSU):
      self.samplen = 4
      self.ntr = (self.filesize) / (240 + self.samplen*self.ns)
      return

    if (self.bhead['format'] == 3):
      self.samplen = 2
    elif (self.bhead['format'] == 8):
      self.samplen = 1
    else:
      self.samplen = 4

    self.ntr = (self.filesize - 3600) / (240 + self.samplen*self.ns)

  # --------------------------------------------------------------------

  def sNormalize (self, traces):

    '''
    Utility function that takes seismic traces and returns an amplitude
    normalized version.

    :param traces: List or array of traces to normalize.
    :type traces: ndarray, list
    '''

    if not _np.iterable(traces):
      traces = [traces]

    self._maybePrint('Normalizing each trace to unit amplitude.\n')

    return _np.array([trace/max(abs(trace.max()),abs(trace.min())) for trace in traces])

  # --------------------------------------------------------------------

  def writeFlat (self, outfilename):
    '''
    Outputs seismic traces as a flat file in IEEE floating point and
    native endian.

    :param outfilename: Filename for new flat datafile.
    :type outfilename: str

    *Experimental*
    '''

    ntraces = len(self.trhead)

    ns = self.ns

    fp_out = open(outfilename, "w")

    for trace in xrange(1, ntraces+1):
      self._fp.seek(self._calcDataOffset(trace,ns))
      fp_out.write(self._fp.read(ns*4))

    fp_out.close()

  # --------------------------------------------------------------------

  def writeSEGY (self, outfilename, traces, headers=None):
    '''
    Outputs seismic traces in a new SEG-Y file, optionally using the headers
    from the existing dataset.

    :param outfilename: Filename for new SEG-Y datafile.
    :type outfilename: str
    :param traces: Array of seismic traces to output.
    :type traces: ndarray, list
    :param headers: List of three headers: [thead, bhead, trhead].  If omitted, the existing headers in the SEGYFile instance are used. *thead* is an ASCII-formatted 3200-byte text header. *bhead* is a list of binary header values similar to SEGYFile.bhead.  *trhead* is a list or list-like object of trace header values.
    :type headers: list, None
    '''

    if (headers == None):
      thead=self.thead
      bhead=self.bhead
      trhead=self.trhead
    else:
      [thead, bhead, trhead] = headers

    ntraces = len(traces)

    ns = self.ns

    fp = open(outfilename, 'w+b')

    fp.write(thead.encode('IBM500')[:3200])
    
    bheadbin = _struct.pack(BHEADSTRUCT, *[bhead[key] for key in BHEADLIST]) + '\x00' * 340

    fp.write(bheadbin)

    for i, trace in enumerate(traces):
      trheadbin = _struct.pack(TRHEADSTRUCT, *[trhead[i][key] for key in TRHEADLIST]) + '\x00' * 60
      fp.write(trheadbin)
      tracetemp = _struct.pack('>%df'%(ns,), *list(trace))
      fp.write(tracetemp)

    fp.close()

  # --------------------------------------------------------------------

  def writeSU (self, outfilename, traces, trhead=None):
    '''
    Outputs seismic traces in a new CWP SU file, optionally using the headers
    from the existing dataset.

    :param outfilename: Filename for new SU datafile.
    :type outfilename: str
    :param traces: Array of seismic traces to output.
    :type traces: ndarray, list
    :param trhead: List or list-like object of trace header values.  If omitted, the existing headers in the SEGYFile instance are used.
    :type trhead: list, None
    '''

    if (trhead == None):
      trhead=self.trhead

    ntraces = len(traces)

    ns = self.ns

    fp = open(outfilename, 'w+b')

    for i, trace in enumerate(traces):
      trheadbin = _struct.pack(TRHEADSTRUCT, *[trhead[i][key] for key in TRHEADLIST]) + '\x00' * 60
      fp.write(trheadbin)
      tracetemp = _struct.pack('>%df'%(ns,), *list(trace))
      fp.write(tracetemp)

    fp.close()

  # --------------------------------------------------------------------

  def __len__ (self):
    return self.ntr

