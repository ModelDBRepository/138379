
This simulation was tested/developed on LINUX systems, but may run on Microsoft Windows or Mac OS.

To run, you will need the NEURON simulator (available at http://www.neuron.yale.edu)

Unzip the contents of fdemo.zip to a new directory.

compile the mod files from the command line with:
 nrnivmodl *.mod

That will produce an architecture-dependent folder with a script called special.
On 64 bit systems the folder is x86_64. To run the simulation from the command line:
 ./x86_64/special
then NEURON will start and load the mechanisms (cell types, etc.)
then from the NEURON prompt:
 load_file("mosinit.hoc")

That will load the simulation and all required files. Network and inputs will be setup.
Then the simulation will be run for 20 seconds of simulation time. The simulation duration
is modifiable via the mytstop parameter in mosinit.hoc. Note that setup of the network may
take 10-30 seconds, depending on your processor speed, amount of RAM, and whether using
NetStim (usens flag in mosinit.hoc). Once the simulation has run, two graphs will be displayed,
showing the spike raster and LFP from a single column. The spike raster is arranged with y-axis
as cell identifier and x-axis as time in milliseconds. The y-axis is further arranged in order
of layer/type displayed with labels in the graph (top is layer 2, bottom is layer 6).

Once the spikes and LFP are displayed, the multiunit activity vectors for excitatory and inhibitory
cells are formed and their power spectra are calculated and displayed in separate plots for raw
(if the drawraw variable declared in mosinit.hoc is set to 1 before getpsd is called) and smoothed
power spectra. The red (blue) traces indicate power from excitatory (inhibitory) MUAs. The PSD smoothing
level is set by the boxszdef variable, and is normalized to the length of the simulation duration within
the getpsd function.

Note that the paper used Matlab's pmtm and fft functions which are only commercially available.
To allow use/test of this demo to the widest available audience, the NEURON spctrm Vector function
was used instead. Some differences in spectral output are visible depending on which spectral
methods are employed. See the getpsd function in mosinit.hoc for other options for spectral methods
that are freely available or contact samn at neurosim dot downstate dot edu for further information
and/or help using these other methods, including Matlab.

References:

 This simulation was used in an article at Frontiers in Computational Neuroscience,
 special issue on Structure, dynamics and function of brains:
  Citation: Neymotin SA, Lee H, Park E, Fenton AA and Lytton WW (2011). Emergence of physiological oscillation
  frequencies in a computer model of neocortex. Front. Comput. Neurosci. 5:19. doi: 10.3389/fncom.2011.00019
  Received: 19 Oct 2010; Accepted: 01 Apr 2011. 
  Edited by:   Ad Aertsen, Albert Ludwigs University, Germany
  Reviewed by: Imre Vida, University of Glasgow, UK 
               Michael Schmuker, Freie Universtiät Berlin, Germany 
               Maxim Bazhenov, University of California, USA 
 
 article available at:
  http://www.frontiersin.org/Computational_Neuroscience/10.3389/fncom.2011.00019/abstract

20110418 Updated to run on mswin.  -ModelDB Administrator
