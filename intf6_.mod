: $Id: intf6.mod,v 1.58 2011/02/04 05:39:43 samn Exp $

:* main COMMENT
COMMENT

intf6.mod was branched from intf.mod version 847 on 10jul13 -- look at intf.mod RCS
log/diffs to see anything prior. note that AM2,NM2,GA2 code was mostly taken from
intf.mod version 815.

artificial cell incorporating 4 input weights with different time constants and signs
typically a fast AMPA, slow NMDA, and fast GABAA
features:
  1. Mg dependence for NMDA activation
  2. depolarization blockade
  3. AHP affects both Vm and refractory period  (adaptation)
  4. decrementing excitatory and/or inhibitory activity post spk (another adaptation)
since artificial cells only do calculations when they receive events, a set of vec
  pointers are maintained to allow state var information storage when event arrives
  (see initrec() and record())
ENDCOMMENT

:* main VERBATIM block
VERBATIM

#include "misc.h"

#include <unistd.h>

#ifdef NRN_MECHANISM_DATA_IS_SOA
#define get_dparam(prop) _nrn_mechanism_access_dparam(prop)
#define get_type(prop) _nrn_mechanism_get_type(prop)
#define id0ptr(prop) static_cast<id0*>(_nrn_mechanism_access_dparam(prop)[2].get<void*>())
#else
#define get_dparam(prop) prop->dparam
#define get_type(prop) prop->_type
#define id0ptr(prop) (*((id0**)&(prop->dparam[2])))
#endif

static int ctt(unsigned int, char**);
static void setdvi2(double*,double*,char*,int,int);
void gsort3 (double *, Point_process **, char*, int, double *, Point_process **,char*);
void gsort2 (double *, Point_process **, int, double *, Point_process **);

#define PI 3.14159265358979323846264338327950288419716939937510
#define nil 0
#define CTYPp 41 // CTYPp>CTYPi from labels.hoc
#define SOP (((id0*) _p_sop)->vp)
#define IDP (*((id0**) &(_p_sop)))
#define NSW 100  // just store voltages
#define NSV 11  // 10 state variables (+ 1 for time)
#define FOFFSET 100 // flag offset for net_receive()
#define WRNUM 5  // a single INTF6 can store into this many ww field vecs
#define DELM(X,Y) (*(pg->delm+(X)*CTYPi+(Y)))
#define DELD(X,Y) (*(pg->deld+(X)*CTYPi+(Y)))
#define DVG(X,Y) ((int)*(pg->dvg+(X)*CTYPi+(Y)))
// #define DVG(X,Y,Z) ((int)*(pg->dvg+(X)*CTYPi+(Y)))
#define WMAT(X,Y,Z) (*(pg->wmat+(X)*CTYPi*STYPi+(Y)*STYPi+(Z)))
#define WD0(X,Y,Z)  (*(pg->wd0 +(X)*CTYPi*STYPi+(Y)*STYPi+(Z)))
#define NUMC(X) (*(pg->numc+(X)))
#define HVAL(X) (*(hoc_objectdata[(hoc_get_symbol((X)))->u.oboff]._pval))
#define HPTR(X) (hoc_objectdata[(hoc_get_symbol((X)))->u.oboff]._pval)

// for recording (?)
typedef struct VPT {
 unsigned int  id;
 unsigned int  size;
 unsigned int  p;
 IvocVect* vv[NSV];
 double* vvo[NSV];
} vpt;

// each column can have one of these
typedef struct POSTGRP { // postsynaptic group
  double *dvg; double *delm; double *deld; double *ix; double *ixe; double *wmat; double *wd0;
  double *numc; // num cells by type
  unsigned int col; // COLUMN ID
  double* jrid; // for recording SPIKES
  double* jrtv;
  IvocVect* jridv;
  IvocVect* jrtvv;
  unsigned int jtpt,jtmax,jrmax; 
  unsigned long jri,jrj;
  unsigned long spktot,eventtot;
  double *isp, *vsp, *wsp, *sysp; // arrays for external inputs
  int  vspn;
  double *lastspk; // array with last spike times for all cells
  unsigned int cesz; // size of ce
  Object *ce; // cell list
  struct POSTGRP *next;
} postgrp;

// each cell gets one of these, note that postgrp pointer is an element
typedef struct ID0 {
  vpt     *vp;
  postgrp *pg; // <-- pointer to get to postsynaptic cells, shared by cells in a column
  float    wscale[WRNUM];
  Point_process **dvi; // each cell has a divergence list
  Point_process **cvi; // each cell has a convergence list
  double *del;         // each syn has its own intrinsic delay
  char *syns;          // each syn has a type
  unsigned char *sprob;    // each syn has a firing probability 0-255->0-1
  double* wgain; // gain for synapses - used for plasticity
  int* peconv; // IDs of E cells converging on this cell
  int econvsz;
  double* syw1; // synaptic weights (parallel to divergence list) -- used for AMPA,GABAA
  double* syw2; // synaptic weights -- used for NMDA,GABAB -- these lists only used when wsetting==1
  unsigned int dvt;
  unsigned int  id; // within-COLUMN ID
  unsigned int col; // COLUMN
  unsigned int rvb;
  unsigned int rvi;
  unsigned int spkcnt;
  unsigned int blkcnt;
  unsigned int gid; // global ID
  int rve;
  char   wreci[WRNUM]; // since use -1 as a flag
  char   errflag;
  // type -> vbr MUST REMAIN unbroked BLOCK -- see flag()
  // when adding flags also augment iflags, iflnum
  // only use first 3 letters with flag() -- see iflags
  unsigned char     type;  // | 
  unsigned char     inhib; // | 
  unsigned char     record;// |
  unsigned char     wrec;  // |
  unsigned char     jttr;  // |
  unsigned char     input; // |
  unsigned char     vinflg;// |
  unsigned char     invl0; // |
  unsigned char     jcn;   // |
  unsigned char     dead;  // |
  unsigned char     vbr;   // |
           char     dbx;   // |
           char     flag;  // |
           char     out;   // |
  // end BLOCK
} id0;

// globals -- range vars must be malloc'ed in the CONSTRUCTOR
static vpt *vp; // vp, pg, ip are used as temporary pointers
static id0 *ip, *qp, *rp;
static int inumcols=0;
static int ippgbufsz=0;
static postgrp **ppg=0x0;
static postgrp *pg;
static unsigned int nextGID = 0;
static Object *CTYP;
static Point_process *pmt, *tpnt;
static char *name;
static Symbol* cbsv;
// iflags string use to find flags -- note that only 1st 3 chars are used to identify
static char iflags[100]="typ inh rec wre jtt inp vin inv jcn dea vbr dbx fla out"; 
static char iflnum=14, iflneg=11, errflag;      // turn on after generating an error message
static double *jsp, *invlp;
static void lop (Object *ob, unsigned int i); // accessed by all INTF6
id0* getlp (Object *ob, unsigned int i); // get pointer from list
static void applyplast (id0* ppo,double pospkt, double phase, double pinc);
static double vii[NSV];   // temp storage
static unsigned int wwpt,wwsz,wwaz; // pointer, size for shared ww vectors
static unsigned int sead, spikes[CTYPp], blockcnt[CTYPp]; // 'sead' vs global 'seed'/ used elsewhere
static unsigned int AMo[CTYPp],NMo[CTYPp],GAo[CTYPp]; // count overages for types
static unsigned int AMo2[CTYPp],NMo2[CTYPp],GAo2[CTYPp]; // count overages for types (farther from soma)
static char* CNAME[CTYPp]; // 20 should be > CTYPi
static int cty[CTYPp], process, ctymap[CTYPp];
static int CTYN, CTYPi, STYPi, dscrsz; // from labels.hoc
static double qlimit, *dscr;
FILE *wf1, *wf2, *tf;
IvocVect* ww[NSW];
double* wwo[NSW];
static int AM=0, NM=1, GA=2, GB=3, AM2=4, NM2=5, GA2=6, SU=3, IN=4, DP=2; // from labels.hoc
static double wts[13],hsh[13];  // for jitcons to use as a junk pointer
static void spkoutf2();
ENDVERBATIM

:* NEURON, PARAMETER, ASSIGNED blocks
NEURON {
  ARTIFICIAL_CELL INTF6
  RANGE VAM, VNM, VGA, AHP           :::: cell state variables
  RANGE VAM2, VNM2, VGA2                  :::: state vars for distal dend inputs
  RANGE Vm                                :::: derived var
  : parameters
  RANGE tauAM, tauNM, tauGA            :::: synaptic params
  RANGE tauAM2, tauNM2, tauGA2         :::: synaptic params meant for distal dends
  RANGE tauahp, ahpwt                  :::: intrinsic params
  RANGE tauRR , RRWght                 :::: relative refrac. period tau, wght of Vblock-VTH for refrac
  RANGE RMP,VTH,Vblock,VTHC,VTHR       :::: Vblock for depol blockade
  RANGE nbur,tbur,refrac               :::: burst size, interval; refrac period and extender
  RANGE invl,oinvl,WINV,invlt           :::: interval bursting params
  RANGE Vbrefrac                        
  RANGE STDAM, STDNM, STDGA             :::: specific amounts of STD for each type of synapse
  RANGE mg0                             :::: sensitivity to Mg2+, used in rates
  RANGE maxnmc                          :::: maximum NMDA 'conductance', used in rates
  RANGE plastinc : increment for plasticity - parameter at postsynaptic side
  GLOBAL EAM, ENM, EGA,mg               :::: "reverse potential" distance from rest
  GLOBAL spkht, wwwid,wwht              :::: display: spike height, width/ht for pop spikes
  GLOBAL stopoq                         :::: flags: stop if q is empty, use STD
  : other stuff
  POINTER sop                          :::: Structure pointer for other range vars
  RANGE  spck,xloc,yloc,zloc
  RANGE  t0,tg,twg,refractory,trrs :::: t0,tg save times for analytic calc
  RANGE  cbur                         :::: burst statevar
  RANGE  WEX                          :::: weight of external input < 0 == inhib, > 0 ==excit
  RANGE  EXSY                         :::: synapse target of external input
  RANGE  lfpscale                     :::: scales contribution to lfp, only if cell is being recorded in wrecord
  RANGE  tauplast                     :::: plasticity time-constant - not used right now
  GLOBAL vdt,nxt,RES,ESIN,Psk      :::: table look up values for exp,sin
  GLOBAL prnum, nsw, rebeg             :::: for debugging moves
  GLOBAL subsvint, jrsvn, jrsvd, jrtime, jrtm :::: output params
  GLOBAL DEAD_DIV, seedstep            :::: dead cells on div list?
  GLOBAL seaddvioff                    :::: seed offset for dvi/del 
  GLOBAL WVAR,DELMIN
  GLOBAL savclock,slowset,FLAG  
  GLOBAL tmax,installed,verbose        :::: simplest output
  GLOBAL pathbeg,pathend,PATHMEASURE,pathidtarg,pathtytarg,seadsetting,pathlen
  GLOBAL maxplastw : maximum plasticity gain factor
  GLOBAL maxplastt : maximum difference in time between spikes to apply plasticity over
  GLOBAL plaststartT : when plasticity is turned on
  GLOBAL plastendT   : when plasticity is turned off
  GLOBAL resetplast  : whether to reset all wgain entries to 1 at start of run
  GLOBAL wsetting : setting for weights. 0=use WMAT,WD0. 1=use syw1,syw2.
}

PARAMETER {
  tauAM = 10 (ms)
  tauNM = 300 (ms)
  tauGA = 10 (ms)
  tauAM2 = 20 (ms)
  tauNM2 = 300 (ms)
  tauGA2 = 20 (ms)
  invl =  100 (ms)
  WINV =  0
  ahpwt = 0
  tauahp= 10 (ms)
  tauRR = 6 (ms)
  refrac = 5 (ms)
  Vbrefrac = 20 (ms)
  RRWght = 0.75
  wwwid = 10
  wwht = 10
  VTH = -45      : fixed spike threshold
  VTHC = -45
  VTHR = -45
  Vblock = -20   : level of depolarization blockade
  vdt = 0.1      : time step for saving state var
  mg = 1         : for NMDA Mg dep.
  sop=0
  nbur=1
  tbur=2
  RMP=-65
  EAM = 65
  ENM = 90
  EGA = -15
  spkht = 50
  prnum = -1
  nsw=0
  rebeg=0
  subsvint=0
  jrsvn=1e4 jrsvd=1e4 jrtime=-1 jrtm=-1
  seedstep=44340
  seaddvioff=9102098713763e-134
  DEAD_DIV=1
  WVAR=0.2
  stopoq=0
  PATHMEASURE=0
  verbose=1
  seadsetting=0
  pathidtarg=-1
  DELMIN=1e-5 : min delay to bother using queue -- otherwise considered simultaneous
  STDAM=0
  STDNM=0
  STDGA=0
  mg0 = 3.57
  maxnmc = 1.0
  lfpscale = 1.0
  maxplastw = 10.0
  maxplastt = 10.0
  plastinc = 0.01
  tauplast = 1
  plaststartT = -1 : default of -1 means always on (when seadsetting==3)
  plastendT = -1   : default of -1 means always on (when seadsetting==3)
  resetplast = 1   : default to reset wgain entries to 1 at start of run
  wsetting = 0 : default -- use WMAT,WD0
}

ASSIGNED {
  Vm VAM VNM VGA AHP VAM2 VNM2 VGA2
  t0 tg twg refractory nxt xloc yloc zloc trrs
  WEX EXSY RES ESIN Psk cbur invlt oinvl tmax spck savclock slowset FLAG
  installed
  pathbeg pathend pathtytarg pathlen
}

:* CONSTRUCTOR, DESTRUCTOR, INITIAL
:** CONSTRUCT: create a structure to save the identity of this unit and char integer flags
CONSTRUCTOR {
  VERBATIM 
  { int lid,lty,lin,lco,lgid,i; unsigned int sz;
    if (ifarg(1)) { lid=(int) *getarg(1); } else { lid= UINT_MAX; } // ID
    if (ifarg(2)) { lty=(int) *getarg(2); } else { lty= -1; } // type
    if (ifarg(3)) { lin=(int) *getarg(3); } else { lin= -1; } // inhib
    if (ifarg(4)) { lco=(int) *getarg(4); } else { lco= -1; } // column
    _p_sop = (double*)ecalloc(1, sizeof(id0)); // important that calloc sets all flags etc to 0
    ip = IDP;
    ip->id=lid; ip->type=lty; ip->inhib=lin; ip->col=lco; 
    ip->pg=0x0; ip->dvi=0x0; ip->sprob=0x0;  ip->syns=0x0; ip->wgain=0x0; ip->peconv=0x0; ip->syw1 = ip->syw2 = 0x0;
    ip->dead = ip->invl0 = ip->record = ip->jttr = ip->input = 0; // all flags off
    ip->dvt = ip->vbr = ip->wrec = ip->jcn = ip->out = 0;
    for (i=0;i<WRNUM;i++) {ip->wreci[i]=-1; ip->wscale[i]=-1.0;}
    ip->rve=-1;
    pathbeg=-1;
    slowset=0; 
    ip->gid = nextGID++; // global identifier
    process=(int)getpid();
    CNAME[SU]="SU"; CNAME[DP]="DP"; CNAME[IN]="IN";
    if (installed==2.0 && ip->pg) { // jitcondiv was previously run
      sz=ivoc_list_count(ip->pg->ce);
      if(verbose) printf("\t**** WARNING new INTF6 created: may want to rerun jitcondiv ****\n");
    } else installed=1.0; // set or reset it
    cbsv=0x0;
  }
  ENDVERBATIM
}

DESTRUCTOR {
  VERBATIM { 
  free(IDP);
  }
  ENDVERBATIM
}

:** INITIAL
INITIAL { LOCAL id
  reset() 
  t0 = 0
  tg = 0
  twg = 0
  trrs = 0
  tmax=0
  pathend=-1
  pathlen=0
  VERBATIM
  { int i,ix;
  ip=IDP;
  _lid=(double)ip->id;
  ip->spkcnt=0;
  ip->blkcnt=0;
  ip->errflag=0;
  ip->pg->lastspk[ip->id]=-1;
  for (i=0;i<CTYN;i++){ix=cty[i]; blockcnt[ix]=spikes[ix]=AMo[ix]=NMo[ix]=GAo[ix]=AMo2[ix]=NMo2[ix]=GAo2[ix]=0;}
  if(seadsetting==3 && resetplast && ip->wgain) for(i=0;i<ip->dvt;i++) ip->wgain[i]=1.0; // reset learning
  }
  ENDVERBATIM
  jrsvn=jrsvd jrtime=jrtm
  : init with vinset(0) if will turn on via a NetCon with w5=1
  if (vinflag()) { randspk() net_send(nxt,2)}
  if (recflag()) { recini() } : recini() resets for recording, cf recinit()
  if (pathbeg==id) { 
    stoprun=0 
    net_send(0,2) 
  } : send at time 0
  rebeg=0 : will reset this to restart storage for rec,wrec
}

PROCEDURE reset () {
  Vm = RMP
  VAM = 0
  VNM = 0
  VGA = 0
  AHP=0
  VAM2 = 0
  VNM2 = 0
  VGA2 = 0
  invlt = -1
  t0 = t
  tg = t
  twg = t
  trrs = t
  cbur = 0 : # bursts left to 0, just in case
  spck = 0 : spike count to 0
  refractory = 0 : 1 means cell is absolute refractory
  VTHC=VTH :set current threshold to absolute threshold value
  VTHR=VTH :set this one too to make sure it's initialized
}

VERBATIM
unsigned int GetDVIDSeedVal(unsigned int id) {
  double x[2];
  if (seadsetting==1) { 
    sead=((unsigned int)ip->id+seaddvioff)*1e6;
  } else { 
    if (seadsetting==2) printf("Warning: GetDVIDSeedVal called with wt rand turned off\n");
    x[0]=(double)id; x[1]=seaddvioff;
    sead=hashseed2(2, x);
  }
  return sead;
}
ENDVERBATIM

: seed for divergence and delays -- not yet used
FUNCTION DVIDSeed(){
  VERBATIM
  return (double)GetDVIDSeedVal(IDP->id);
  ENDVERBATIM
}

:* NET_RECEIVE
NET_RECEIVE (wAM,wNM,wGA,wGB,wAM2,wNM2,wGA2,wflg) { LOCAL tmp,jcn,id
  INITIAL { wAM=wAM wNM=wNM wGA=wGA wGB=wGB wAM2=wAM2 wNM2=wNM2 wGA2=wGA2 wflg=0}
  : intra-burst, generate next spike as needed
VERBATIM
  id0 *ppre; int prty,poty,prin,prid,poid,ii,sy,nsyn,distal; double STDf,wgain,syw1,syw2; //@

ENDVERBATIM
  tmax=t
  VERBATIM
  if (stopoq && !qsz()) stoprun=1;
  ip=IDP; pg=ip->pg; ppre = 0x0; poid=ip->id;
  if (ip->dead) return; // this cell has died
  _ljcn=ip->jcn; _lid=ip->id;
  tpnt = _pnt; // this pnt
  if (PATHMEASURE) { // do all code for this
    if (_lflag==2 || _lflag<0) { // on the callback -- distribute to divergence list
      double idty; int i;
      if (_lflag==2) ip->flag=-1; 
      idty=(double)(FOFFSET+ip->id)+1e-2*(double)ip->type+1e-3*(double)ip->inhib+1e-4;
      for (i=0;i<ip->dvt && !stoprun;i++) if (ip->sprob[i]) {
        (*pnt_receive[get_type(ip->dvi[i]->_prop)])(ip->dvi[i], wts, idty);
        // restore pointers each time
#ifdef NRN_MECHANISM_DATA_IS_SOA
        neuron::legacy::set_globals_from_prop(_pnt->_prop, _ml_real, _ml, _iml);
#else
        _p = _pnt->_prop->param;
#endif
        _ppvar = get_dparam(_pnt->_prop);
        ip = IDP;
      }
      return;  // else see if destination has been reached
    } else if (_lflag!=2 && (pathtytarg==(double)ip->type || pathidtarg==(double)ip->id)) {
      if (pathend==(double)ip->id) return; // means that coming back here again
      ip->flag=(unsigned char)floor(t)+1; // type-target or id-target
      pathend=(double)ip->id; 
      pathlen=tmax+1; // tmax gives pathlength
      stoprun=1.; 
      return;
      // deadends:visited || no output  ||stopped
    } else if (ip->flag   || ip->dvt==0 || stoprun) {
      return; // inhib cell is a deadend; don't revisit anyone
    } else if (ip->inhib) {
      if (!ip->flag) ip->flag=(unsigned char)floor(t)+1;
    } else { // first callback will be from the stim
      ip->flag=(unsigned char)floor(t)+1;
   #if defined(t)
      net_send((void**)0x0, wts,tpnt,t+1.,-1.); // the callback call
  #else
      net_send((void**)0x0, wts,tpnt,1.,-1.); // the callback call
  #endif
      return;
    }
  }

  if (_lflag==OK) { FLAG=OK; flag(); return; } // identify internal call with errflag
  if (_lflag<0) { callback(_lflag); return; }
  pg->eventtot+=1;

  // if(flag==0) { printf("flag==0!\n"); }
  ENDVERBATIM
VERBATIM
  if (ip->dbx>2) 
ENDVERBATIM
{ 
    pid() 
    printf("DB0: flag=%g Vm=%g",flag,VAM+VNM+VGA+RMP+AHP+VAM2+VNM2+VGA2)
    if (flag==0) { printf(" (%g %g %g %g %g %g %g)",wAM,wNM,wGA,wAM2,wNM2,wGA2,wflg) }
    printf("\n")
  }
: causes of spiking: between VTH and Vblock, random from vsp (flag 2), within burst
:** JITcon code - only meant for intra-COLUMN events
  if (flag>=FOFFSET) { : jitcon -- set up weights on the fly
    VERBATIM {
      // find type of presyn
      prid = (int)(_lflag-FOFFSET); // that correct? - if not, put prid in wts[2]
      poty=(int)ip->type;
      prty=(int)(1e2*(_lflag-floor(_lflag)));
      prin=(int)(1e3*(_lflag-floor(_lflag)-prty*1e-2)); // stuffed into this flag
      distal = ((int) (_lflag * 1e5 + 0.5)) % 2;       
      if(distal){ sy=prin?GA2:AM2; } else { sy=prin?GA:AM; }
      // if(verbose>4) printf("receive: %s->%s, prin=%d, distal=%d, sy=%d, _lflag=%.10f\n",\
      //                    CNAME[ctymap[prty]],CNAME[ctymap[poty]],prin,distal,sy,_lflag);
      STDf=_args[0]; // save value -- for short-term changes
      wgain=_args[1]; // save value -- for plasticity
      syw1=_args[2]; // save value -- for non-MATRIX weight 1 -- only used when wsetting==1
      syw2=_args[3]; // save value -- for non-MATRIX weight 2 -- only used when wsetting==1
      if(ip->dbx<-1) printf("prid%d,poid%d,wgain=%g\n",prid,poid,wgain); 
      for (ii=0;ii<=6;ii++) _args[ii]=0.; // clear _args (stores weights for later) to be safe
      if (seadsetting==3) { // plasticity mode is on
        ppre = getlp(pg->ce,prid);  // get pointer to presynaptic cell
        if(ip->dbx<-1) printf("ppre%p,pre%d->po%d,wg=%g\n",ppre,prid,ip->id,wgain);
        if(ppre->inhib) ppre = 0x0; // only care about presynaptic E cells for plasticity
      }
      if(ppre) { // presynaptic E cell AND plasticity mode is on
        for (ii=sy,nsyn=0;ii<sy+2;ii++) {
          if(ii==AM2 || ii==AM) { // AMPA plasticity factor
            if(wsetting==1.0) { // non-MATRIX weights and AMPA plasticity if(ip->dbx<-1) printf("pre%d->po%d,sy=%d,wg=%g,w=%g\n",prid,ip->id,ii,wgain,_args[ii]);
              _args[ii] = ii == sy ? syw1 * wgain : syw2 * wgain;               
            } else { // MATRIX weights and AMPA plasticity
              _args[ii]=wgain*WMAT(prty,poty,ii)*WD0(prty,poty,ii);              
            }
            if(ip->dbx<-1) printf("pre%d->po%d,sy=%d,wg=%g,w=%g\n",prid,ip->id,ii,wgain,_args[ii]);
          } else { // non-AMPA -->> no plasticity applied
            if(wsetting==1.0) { // non-MATRIX weights and non AMPA
              _args[ii] = ii == sy ? syw1 : syw2;
            } else { // MATRIX weights and non AMPA
              _args[ii]=WMAT(prty,poty,ii)*WD0(prty,poty,ii);
            }
          }
          nsyn+=(_args[ii]>0.);
        }
      } else { // no plasticity applied
        if(wsetting==1.0) { // non-MATRIX weights
          _args[sy+0] = syw1;
          _args[sy+1] = syw2;
          nsyn = (_args[sy+0]>0.) + (_args[sy+1]>0.);
        } else { // MATRIX weights
          for (ii=sy,nsyn=0;ii<sy+2;ii++) nsyn+=((_args[ii]=WMAT(prty,poty,ii)*WD0(prty,poty,ii))>0.);
        }
      }
      if (nsyn==0) return; //return for 0-weight events, before changing state vars or Vm
      if (seadsetting==3) { // empty 'if' to skip next clause
      } else if (seadsetting!=2) { // not fixed weights
        if (seadsetting==1) {
          sead=(unsigned int)(floor(_lflag)*ip->id*seedstep); // all integers
        } else { // hash on presynaptic id+FOFFSET,poid,seedstep
          hsh[0]=floor(_lflag); hsh[1]=(double)ip->id; hsh[2]=seedstep;
          sead=hashseed2(3, hsh); // hsh[] is just scratch pad
        }
        mcell_ran4(&sead, &_args[sy], 2, 1.);
        for (ii=sy;ii<sy+2;ii++) { // scale appropriately; 
          _args[ii]=2*WVAR*(_args[ii]+0.5/WVAR-0.5)*WMAT(prty,poty,ii)*WD0(prty,poty,ii);
        }
      }
    }
    ENDVERBATIM
VERBATIM
    if (ip->dbx>2) 
ENDVERBATIM
{ 
      pid() 
      printf("DF: flag=%g Vm=%g",flag,VAM+VNM+VGA+RMP+AHP+VAM2+VNM2+VGA2)
      printf(" (%g %g %g %g %g %g %g)",wAM,wNM,wGA,wAM2,wNM2,wGA2,wflg)
      printf("\n")
    }
:** mid-burst
  } else if (flag==4) { 
    cbur=cbur-1  : count down the spikes
    if (cbur>0) { 
      net_send(tbur,4) 
    } else { : end of burst
      refractory = 1      : signal that this cell is in refractory period
      net_send(refrac, 3) : send event for end of refractory
    }
    tmp=t
VERBATIM
    if (ip->jttr) 
ENDVERBATIM
{ tmp= t+jttr()/10 } 
    if (jcn) { 
      jitcon(tmp)
VERBATIM
      if(ip->out) 
ENDVERBATIM
{ net_event(tmp) } 
    } else { net_event(tmp) }
VERBATIM
    spikes[ip->type]++; //@

ENDVERBATIM
    spck=spck+1
VERBATIM
    if (ip->dbx>0) 
ENDVERBATIM
{ pid() printf("DBA: mid-burst event at %g, %g\n",tmp,cbur) } 
VERBATIM
    if (ip->record) 
ENDVERBATIM
{ recspk(tmp) } 
VERBATIM
    if (ip->wrec) 
ENDVERBATIM
{ wrecord(t) } 
VERBATIM
    return; //@ done

ENDVERBATIM
    : start reading random spike times (or burst times) from vsp vector pointer
    : this is signaled externally from a netstim with wflg=1, will turn off on next stim 
    : (NB wflg used in completely different context for GABAB) ?? is this still true ??
    : this is bad -- should use a special netcon that just handles signals
  } else if (flag==0 && wflg==1) {
VERBATIM
    ip->input=1; //@

ENDVERBATIM
    wflg=2 : set flag to turn off next time an external event comes from here
    randspk() 
    net_send(nxt,2)
VERBATIM
    return; //@ done

ENDVERBATIM
  } else if (flag==0 && wflg==2) { : flag to stop random spikes
VERBATIM
    ip->input=0; //@ inputs that are read from a vector of times -- see randspk()

ENDVERBATIM
    wflg=1  : flag to turn on next time
VERBATIM
    return; //@ done

ENDVERBATIM
  } else if (flag==6) {
VERBATIM
    if(ip->dbx<-1) printf("%d@%g applyplast\n",ip->id,ip->pg->lastspk[ip->id]); //@

ENDVERBATIM
    tmp=t-maxplastt
VERBATIM
    applyplast(ip,_ltmp,-1.0,plastinc); //@

ENDVERBATIM
VERBATIM
    return; //@ done

ENDVERBATIM
  }
  : update state variables
VERBATIM
  if (ip->record) 
ENDVERBATIM
{ record() } 
VERBATIM
  if (ip->wrec) 
ENDVERBATIM
{ wrecord(1e9) } 
:** update state variables: VAM, VNM, VGA
  if (VAM>hoc_epsilon)  { VAM = VAM*EXP(-(t - t0)/tauAM) } else { VAM=0 } :AMPA
  if (VNM>hoc_epsilon)  { VNM = VNM*EXP(-(t - t0)/tauNM) } else { VNM=0 } :NMDA
  if (VGA< -hoc_epsilon){ VGA = VGA*EXP(-(t - t0)/tauGA) } else { VGA=0 } :GABAA    
  if (VAM2>hoc_epsilon) {VAM2 = VAM2*EXP(-(t - t0)/tauAM2) } else { VAM2=0 } :AMPA from distal dends
  if (VNM2>hoc_epsilon) {VNM2 = VNM2*EXP(-(t - t0)/tauNM2) } else { VNM2=0 } :NMDA from distal dends
  if (VGA2< -hoc_epsilon){VGA2 = VGA2*EXP(-(t - t0)/tauGA2) } else { VGA2=0 } :GABAA more distal from soma   

  if(refractory==0){:once refractory period over, VTHC falls back towards VTH
    if(VTHC>VTH) { VTHC = VTH + (VTHR-VTH)*EXP(-(t-trrs)/tauRR) }
  }
  if (AHP< -hoc_epsilon){ AHP = AHP*EXP(-(t-t0)/tauahp) } else { AHP=0 } : adaptation
  t0 = t : finished using t0
  Vm = VAM+VNM+VGA+AHP+VAM2+VNM2+VGA2 : membrane deviation from rest
  if (Vm> -RMP) {Vm= -RMP}: 65 mV above rest
  if (Vm<  RMP) {Vm= RMP} : 65 mV below rest
:*** only add weights if an external excitation
  if (flag==0 || flag>=FOFFSET) { 

    : AMPA Erev=0 (0-RMP==65 mV above rest)
    if (wAM>0) {      
      if (STDAM==0) { VAM = VAM + wAM*(1-Vm/EAM)
      } else        { VAM = VAM + (1-STDAM*STDf)*wAM*(1-Vm/EAM) }
      if (VAM>EAM) { 
VERBATIM
        AMo[ip->type]++; //@

ENDVERBATIM
      } else if (VAM<0) { VAM=0 }
    }
    if (wAM2>0) { : AMPA from distal dends      
      if (STDAM==0) { VAM2 = VAM2 + wAM2*(1-Vm/EAM)
      } else        { VAM2 = VAM2 + (1-STDAM*STDf)*wAM2*(1-Vm/EAM) }
      if (VAM2>EAM) { 
VERBATIM
        AMo2[ip->type]++; //@

ENDVERBATIM
      } else if (VAM2<0) { VAM2=0 }
    }
    : NMDA; Mg effect based on total activation in rates()
    if (wNM>0 && VNM<ENM) { 
      if (STDNM==0) { VNM = VNM + wNM*rates(RMP+Vm)*(1-Vm/ENM) 
      } else        { VNM = VNM + (1-STDNM*STDf)*wNM*rates(RMP+Vm)*(1-Vm/ENM) }
      if (VNM>ENM) { 
VERBATIM
        NMo[ip->type]++; //@

ENDVERBATIM
      } else if (VNM<0) { VNM=0 }
    }
    if (wNM2>0 && VNM2<ENM) { : NMDA from distal dends
      if (STDNM==0) { VNM2 = VNM2 + wNM2*rates(RMP+Vm)*(1-Vm/ENM)
      } else        { VNM2 = VNM2 + (1-STDNM*STDf)*wNM2*rates(RMP+Vm)*(1-Vm/ENM) }
      if (VNM2>ENM) { 
VERBATIM
        NMo2[ip->type]++; //@

ENDVERBATIM
      } else if (VNM2<0) { VNM2=0 }
    }
    : GABAA , GABAA2 : note that all wts are positive
    if (wGA>0 && VGA>EGA) { : the neg here gives the inhibition
      if (STDGA==0) {  VGA = VGA - wGA*(1-Vm/EGA) 
      } else {         VGA = VGA - (1-STDGA*STDf)*wGA*(1-Vm/EGA) }
      if (VGA<EGA) { 
VERBATIM
        GAo[ip->type]++; //@

ENDVERBATIM
VERBATIM
        if (ip->dbx>2) 
ENDVERBATIM
{ 
          pid() printf("DB0A: flag=%g Vm=%g",flag,VAM+VNM+VGA+RMP+AHP+VAM2+VNM2+VGA2)
          if (flag==0) { printf(" (%g %g %g %g %g %g)",wGA,EGA,VGA,Vm,AHP,STDf) }  
VERBATIM
          printf("\nAA:%d:%d\n\n",GAo[ip->type],ip->type); //@ 

ENDVERBATIM
        }
      } else if (VGA>0) { VGA=0 } : if want reversal of VGA need to also edit above
    }
    if (wGA2>0 && VGA2>EGA) { : the neg here gives the inhibition, GABAA2, inputs further from soma
      if (STDGA==0) {  VGA2 = VGA2 - wGA2*(1-Vm/EGA)
      } else {         VGA2 = VGA2 - (1-STDGA*STDf)*wGA2*(1-Vm/EGA) }
      if (VGA2<EGA) { 
VERBATIM
        GAo2[ip->type]++; //@

ENDVERBATIM
VERBATIM
        if (ip->dbx>2) 
ENDVERBATIM
{ 
          pid() printf("DB0A: flag=%g Vm=%g",flag,VAM+VNM+VGA+RMP+AHP+VAM2+VNM2+VGA2)
          if (flag==0) { printf(" (%g %g %g %g %g %g)",wGA2,EGA,VGA2,Vm,AHP,STDf) }  
VERBATIM
          printf("\nAA:%d:%d\n\n",GAo2[ip->type],ip->type); //@ 

ENDVERBATIM
        }
      } else if (VGA2>0) { VGA2=0 } : if want reversal of VGA2 need to also edit above
    }
:*** modulated interval firing; cf invlfire.mod
VERBATIM
    if (ip->invl0) 
ENDVERBATIM
{ 
      Vm = RMP+VAM+VNM+VGA+AHP+VAM2+VNM2+VGA2
      if (Vm>0)   {Vm= 0 }
      if (Vm<-90) {Vm=-90}
      if (invlt==-1) { : activate for first time
        if (Vm>RMP) {
          oinvl=invl
          invlt=t
          net_send(invl,1) 
        }
      } else {
        tmp=shift(Vm)
        if (tmp!=0)  {
          net_move(tmp) 
          if (id()<prnum) {
            pid() printf("**** MOVE t=%g to %g Vm=%g %g,%g\n",t,tmp,Vm,invlt,oinvl) }
        }
      }      
    }
  } else if (flag==1) { : modulated interval firing; cf invlfire.mod
    : Vm=RMP+VAM+VNM+VGA+AHP+VAM2+VNM2+VGA2
    if (WINV<0) { 
      if (jcn) { 
        jitcon(t)
VERBATIM
        if(ip->out) 
ENDVERBATIM
{ net_event(t) } 
      } else { net_event(t) } : bypass activation calculation
VERBATIM
      spikes[ip->type]++; //@

ENDVERBATIM
      spck=spck+1
VERBATIM
      if (ip->dbx>0) 
ENDVERBATIM
{pid() printf("DBC: interval event\n")}  
VERBATIM
      if (ip->record) 
ENDVERBATIM
{ recspk(t) } 
VERBATIM
      if (ip->wrec) 
ENDVERBATIM
{ wrecord(t) } 
    } else {
      tmp = WINV*(1-Vm/EAM)
      VAM = VAM + tmp :: activate interval depolarization
    }
    oinvl=invl
    invlt=t
    net_send(invl,1) 
  } else if (flag==2) { :** flag==2 -- read off external vec (vsp) for next random spike time or single from shock()
VERBATIM
    if (ip->dbx>1) 
ENDVERBATIM
{pid() printf("DBBa: randspk called: %g,%g\n",WEX,nxt)} 
    if (WEX>1e8) { : super-threshold event
      if (jcn) { 
        jitcon(t)
VERBATIM
        if(ip->out) 
ENDVERBATIM
{ net_event(t) } 
      } else { net_event(t) } : bypass activation calculation
VERBATIM
      spikes[ip->type]++; //@

ENDVERBATIM
      spck=spck+1
VERBATIM
      if (ip->dbx>0) 
ENDVERBATIM
{pid() printf("DBB: randspk event @ t=%g\n",t)} 
VERBATIM
      if (ip->record) 
ENDVERBATIM
{ recspk(t) } 
VERBATIM
      if (ip->wrec) 
ENDVERBATIM
{ wrecord(t) } 
    } else if (WEX>0) { : excitatory input
      if(EXSY==AM) {
        tmp = WEX*(1-Vm/EAM)
        VAM = VAM + tmp
      } else if(EXSY==AM2) {
        tmp = WEX*(1-Vm/EAM)
        VAM2 = VAM2 + tmp
      } else if(EXSY==NM) {
        tmp = rates(RMP+Vm)*WEX*(1-Vm/ENM)
        VNM = VNM + tmp
      } else if(EXSY==NM2) {
        tmp = rates(RMP+Vm)*WEX*(1-Vm/ENM)
        VNM2 = VNM2 + tmp
      }
    } else if (WEX<0 && WEX!=-1e9) { : inhibitory input
      if(EXSY==GA) {
        tmp = WEX*(1-Vm/EGA)
        VGA = VGA + tmp
      } else { :GA2
        tmp = WEX*(1-Vm/EGA)
        VGA2 = VGA2 + tmp
      }
    }
    if (WEX!=-1e9) { : code for single shock
      randspk() : will set WEX for next time
      if (nxt>0) { net_send(nxt,2) }
    }
  } else if (flag==3) { 
    refractory = 0 :end of absolute refractory period    
    trrs = t : save time of start of relative refractory period
VERBATIM
    return; //@ done

ENDVERBATIM
  }
:** check for Vm>VTH -> fire
  Vm = VAM+VNM+VGA+RMP+AHP+VAM2+VNM2+VGA2 : WARNING -- Vm defined differently than above
  if (Vm>0)   {Vm= 0 }
  if (Vm<-90) {Vm=-90}
  if (refractory==0 && Vm>VTHC) {
VERBATIM
    if (!ip->vbr && Vm>Vblock) {//@ do nothing

ENDVERBATIM
VERBATIM
      ip->blkcnt++; blockcnt[ip->type]++; return; }//@

ENDVERBATIM
    AHP = AHP - ahpwt
    tmp=t
    : note that jtt indicates jitter while jit indicates 'just-in-time'
VERBATIM
    if (ip->jttr) 
ENDVERBATIM
{ tmp= t+jttr() }  
VERBATIM
    //printf("spk t = %g\n",_ltmp); //@

ENDVERBATIM
VERBATIM
    //printf("a ip->pg->lastspk[%d]=%g\n",ip->id,ip->pg->lastspk[ip->id]); //@

ENDVERBATIM
VERBATIM
    ip->pg->lastspk[ip->id]=_ltmp; //@

ENDVERBATIM
VERBATIM
    //printf("b ip->pg->lastspk[%d]=%g\n",ip->id,ip->pg->lastspk[ip->id]); //@

ENDVERBATIM
    if (jcn) { 
      jitcon(tmp)
VERBATIM
      if(ip->out) 
ENDVERBATIM
{ net_event(tmp) } 
    } else { net_event(tmp) } 
VERBATIM
    spikes[ip->type]++; //@

ENDVERBATIM
    spck=spck+1
VERBATIM
    if (ip->dbx>0) 
ENDVERBATIM
{pid() printf("DBD: %g>VTH(%g) event at %g (STDf=%g)\n",Vm,VTHC,tmp,STDf)} 
VERBATIM
    if (ip->record) 
ENDVERBATIM
{ recspk(tmp) } 
VERBATIM
    if (ip->wrec) 
ENDVERBATIM
{ wrecord(tmp) } 
    VTHC=VTH+RRWght*(Vblock-VTH):increase threshold for relative refrac. period
    VTHR=VTHC :starting thresh value for relative refrac period, keep track of it
    refractory = 1 : abs. refrac on = don't allow any more spikes/bursts to begin (even for IB cells)

    if(seadsetting==3 && plastinc>0.) { : apply learning rule
      if(plaststartT<0 || plastendT<0 || (t>=plaststartT && t<=plastendT)) { : make sure plasticity on now
VERBATIM
        if(ip->dbx<-1) printf("%d@%g applyplast\n",ip->id,ip->pg->lastspk[ip->id]); //@

ENDVERBATIM
VERBATIM
        applyplast(ip,ip->pg->lastspk[ip->id],1.0,plastinc); //@

ENDVERBATIM
        net_send(maxplastt, 6) : event to check for synaptic depression -- not completely accurate
      }
    }

    if (nbur>1) { 
      cbur=nbur-1 net_send(tbur,4) : this is main source of burst events - A.P. firing with bursting
VERBATIM
      return; //@ done

ENDVERBATIM
    } 
VERBATIM
    if (ip->vbr && Vm>Vblock) 
ENDVERBATIM
{ 
      net_send(Vbrefrac,3) 
VERBATIM
      if (ip->dbx>0) 
ENDVERBATIM
{pid() printf("DBE: %g %g\n",Vbrefrac,Vm)} 
VERBATIM
      return; //@ done

ENDVERBATIM
    }
    net_send(refrac, 3) :event for end of abs. refrac., sent separately for IB cells @ end of burst
  }
}

:* ancillary functions
:** jitcon() creates divergence and delays from rand seed
: jcn flags:
: 0 NetCons                            jcn==0
: 3 Jitcon without jitevent            jcn==3 -- eliminated after v669
: 2 Jitcon with callback               jcn==2 -- NOT DEBUGGED
: 1 Jitcon with callback with pointers jcn==1
PROCEDURE jitcon (tm) {
  VERBATIM {
  double mindel, randel, idty, *x; int prty, poty, i, j, k, dv; 
  Point_process *pnt; IvocVect* voi;
  // qsz = nrn_event_queue_stats(stt);
  // if (qsz>=qlimit) { printf("qlimit %g exceeded at t=%g\n",qlimit,t); qlimit*=2; }
  ip=IDP; pg=ip->pg;
  if(verbose>1) printf("col %d , ip %p, pg %p\n",ip->col,ip,pg);
  if (!pg) {printf("No network defined -- must run jitcondiv()\n"); hxe();}
  ip->spkcnt++; // jitcon() called from NET_RECEIVE which sets ip
  if (pg->jrj<pg->jrmax) {  // record spike time and cell ID
    pg->jrid[pg->jrj]=(double)ip->id; pg->jrtv[pg->jrj]=_ltm;
    pg->jrj++;
  } else if (wf2 && pg->jrmax) spkoutf2(); // saving spike times
  pg->jri++;  // keep track of number of spikes
  if (jrtm>0) {
    if (t>jrtime) {
      jrtime+=jrtm;
      spkstats2(1.);
    }
  } else if (jrsvd>0 && pg->jri>jrsvn) { 
    jrsvn+=jrsvd; printf("t=%.02f %ld ",t,ip->pg->jri);
    spkstats2(1.);
  }
  prty=(int)ip->type;
  if (ip->jcn==1) if (ip->dvt>0) {  // first callback
      #if defined(t)
    if (ip->jcn==1) if (ip->dvt>0) net_send((void**)0x0, wts,tpnt,t+ip->del[0],-1.);
      #else
    if (ip->jcn==1) if (ip->dvt>0) net_send((void**)0x0, wts,tpnt,ip->del[0],-1.);
      #endif
  }
  }   
  ENDVERBATIM  
}

: call spkstat from hoc to set global tf if desired for spkstats to file
PROCEDURE spkstats () {
VERBATIM {
  if (ifarg(1)) tf=hoc_obj_file_arg(1); else tf=0x0;
}
ENDVERBATIM
}

: spkoutf() use wf2 for output of indices and times
PROCEDURE spkoutf () {
VERBATIM {
  if (ifarg(2)) {
    wf1=hoc_obj_file_arg(1); // index file
    wf2=hoc_obj_file_arg(2);
  } else if (wf1 != 0x0) {
    spkoutf2();
    wf1=(FILE*)0x0; wf2=(FILE*)0x0;
  }
}
ENDVERBATIM
}

VERBATIM
static void spkoutf2 () {
    fprintf(wf1,"//b9 -2 t%0.2f %ld %ld\n",t/1e3,pg->jrj,ftell(wf2));
    fwrite(pg->jrtv,sizeof(double),pg->jrj,wf2); // write times
    fwrite(pg->jrid,sizeof(double),pg->jrj,wf2); // write id
    fflush(wf1); fflush(wf2);
    pg->jrj=0;
}
ENDVERBATIM

PROCEDURE callhoc () {
  VERBATIM
  if (ifarg(1)) {
    cbsv=hoc_lookup(gargstr(1));
  } else {
    cbsv=0x0;
  }
  ENDVERBATIM
}

: flag 1 means print it to a file, 2 means to both places
PROCEDURE spkstats2 (flag) {
VERBATIM {
  int i, ix, flag; double clk;
  ip=IDP; pg=ip->pg;
  flag=(int)(_lflag+1e-6);
  clk=clock()-savclock; savclock=clock();
  if (cbsv) hoc_call_func(cbsv,0);
  if (tf) fprintf(tf,"t=%.02f;%ld(%g) ",t,pg->jri,clk/1e6); else {
    printf("t=%.02f;%ld(%g) ",t,pg->jri,clk/1e6); }
  for (i=0;i<CTYN;i++) {
    ix=cty[i];
    pg->spktot+=spikes[ix];
    if (tf) {
      fprintf(tf,"%s:%d/%d:%d;%d;%d;%d;%d;%d ",CNAME[i],spikes[ix],\
              blockcnt[ix],AMo[ix],NMo[ix],GAo[ix],AMo2[ix],NMo2[ix],GAo2[ix]);
    } else {
      printf("%s:%d/%d:%d;%d;%d;%d;%d;%d ",CNAME[i],spikes[ix],blockcnt[ix],\
             AMo[ix],NMo[ix],GAo[ix],AMo2[ix],NMo2[ix],GAo2[ix]);
    }
    spck=0;
    blockcnt[ix]=spikes[ix]=0;
    AMo[ix]=NMo[ix]=GAo[ix]=AMo2[ix]=NMo2[ix]=GAo2[ix]=0;
  }
  if (tf && flag==2) {  fprintf(tf,"\nt=%g tot_spks: %ld; tot_events: %ld\n",t,pg->spktot,pg->eventtot); 
  } else if (flag==2) {  printf("\ntotal spikes: %ld; total events: %ld\n",pg->spktot,pg->eventtot); 
  } else if (tf) fprintf(tf,"\n"); else printf("\n");
}
ENDVERBATIM
}

PROCEDURE oobpr () {
VERBATIM {
  int i,ix;
  for (i=0;i<CTYN;i++){ 
    ix=cty[i];
    printf("%d:%d/%d:%d;%d;%d;%d;%d;%d ",ix,spikes[ix],blockcnt[ix],\
           AMo[ix],NMo[ix],GAo[ix],AMo2[ix],NMo2[ix],GAo2[ix]);
  }
  printf("\n");
}
ENDVERBATIM
}

PROCEDURE callback (fl) {
  VERBATIM {
  int i; double idty, idtflg, del0, ddel; id0 *jp; Point_process *upnt; // these must be local
  i=(unsigned int)((-_lfl)-1); // -1,-2,-3 -> 0,1,2
  jp=IDP; upnt=tpnt; del0=jp->del[i]; ddel=0.;
  idty=(double)(FOFFSET+jp->id)+1e-2*(double)jp->type+1e-3*(double)jp->inhib+1e-4;
  while (ddel<=DELMIN) { // check if this del is worth waiting, else just send now
    if (Vblock<VTHC) { 
      wts[0]=0; // send [0,1] for STD
    } else { // STDf=(1-STD)
      wts[0]=(VTHC-VTH)/(Vblock-VTH); // just send [0,1] for STD
    }
    if(seadsetting==3 && !jp->inhib) wts[1]=jp->wgain[i]; else wts[1]=0.0; // send plasticity gain?
    if(wsetting==1.0 && jp->syw1 && jp->syw2) {wts[2]=jp->syw1[i]; wts[3]=jp->syw2[i]; } // non-MATRIX weights?
    idtflg = idty + (1e-5 * jp->syns[i]);
    // if(1) printf("s = %g : flg = %.10f\n",(1e-5*jp->syns[i]),idtflg);
    if (jp->sprob[i]) (*pnt_receive[get_type(jp->dvi[i]->_prop)])(jp->dvi[i], wts, idtflg);
#ifdef NRN_MECHANISM_DATA_IS_SOA
    neuron::legacy::set_globals_from_prop(upnt->_prop, _ml_real, _ml, _iml);
#else
    _p = upnt->_prop->param;
#endif
    _ppvar = get_dparam(upnt->_prop); // restore pointers
    i++;
    if (i>=jp->dvt) return 0; // ran out
    ddel=jp->del[i]-del0;   // delays are relative to event; use difference in delays
  }
  // skip over pruned outputs and dead cells:
  while (i<jp->dvt && (!jp->sprob[i] || id0ptr(jp->dvi[i]->_prop)->dead)) i++;
  if (i<jp->dvt) {
    ddel= jp->del[i] - del0;;
  #if defined(t)
    net_send((void**)0x0, wts,upnt,t+ddel,(double) -(i+1)); // next callback
  #else
    net_send((void**)0x0, wts,upnt,ddel,(double) -(i+1)); // next callback
  #endif
  }
  } 
  ENDVERBATIM
}

: DEAD_DIV not checked in mkdvi()
: mkdvi() create the connectivity vectors for a random network
PROCEDURE mkdvi () {
VERBATIM {
  int i,j,k,prty,poty,dv,dvt,dvii; double *x, *db, *dbs; 
  Object *lb;  Point_process *pnnt, **da, **das;
  ip=IDP; pg=ip->pg;//this should only be called after jitcondiv()
  if (ip->dead) return 0;
  prty=ip->type;
  sead=GetDVIDSeedVal(ip->id);//seed for divergence and delays
  for (i=0,k=0,dvt=0;i<CTYN;i++) { // dvt gives total divergence
    poty=cty[i];
    dvt+=DVG(prty,poty);
  }
  da =(Point_process **)malloc(dvt*sizeof(Point_process *));
  das=(Point_process **)malloc(dvt*sizeof(Point_process *)); // das,dbs for after sort
  db =(double *)malloc(dvt*sizeof(double)); // delays
  dbs=(double *)malloc(dvt*sizeof(double)); // delays
  for (i=0,k=0,dvii=0;i<CTYN;i++) { // cell types in cty[]
    poty=cty[i];
    dv=DVG(prty,poty);
    if (dv>0) {
      sead+=dv;
      if (dv>dscrsz) {
        printf("B:Divergence exceeds dscrsz: %d>%d for %d->%d\n",dv,dscrsz,prty,poty); hxe(); }
      mcell_ran4(&sead, dscr ,  dv, pg->ixe[poty]-pg->ix[poty]+1);
      for (j=0;j<dv;j++) {
        if (!(lb=ivoc_list_item(pg->ce,(unsigned int)floor(dscr[j]+pg->ix[poty])))) {
          printf("INTF6:callback %g exceeds %d for list ce\n",floor(dscr[j]+pg->ix[poty]),pg->cesz); 
          hxe(); }
        pnnt=(Point_process *)lb->u.this_pointer;
        da[j+dvii]=pnnt;
      }
      mcell_ran4(&sead, dscr , dv, 2*DELD(prty,poty));
      for (j=0;j<dv;j++) {
        db[j+dvii]=dscr[j]+DELM(prty,poty)-DELD(prty,poty); // +/- DELD
        if (db[j+dvii]<0) db[j+dvii]=-db[j+dvii];
      }
      dvii+=dv;
    }
  }
  gsort2(db,da,dvt,dbs,das);
  ip->del=dbs;   ip->dvi=das;   ip->dvt=dvt; ip->syns=(char*)calloc(dvt,sizeof(char));
  ip->sprob=(unsigned char *)malloc(dvt*sizeof(char *)); // release probability
  for (i=0;i<dvt;i++) ip->sprob[i]=1; // start out with all firing
  free(da); free(db); // keep das,dbs which are assigned to ip->dvi bzw ip->del
  }
ENDVERBATIM
}

:* paths
PROCEDURE patha2b () {
  VERBATIM
  int i; double idty, *x; static Point_process *_pnt; static id0 *ip0;
  ip=IDP; pg=ip->pg;
  pathbeg=*getarg(1); pathidtarg=*getarg(2);
  pathtytarg=-1;  PATHMEASURE=1; pathlen=stopoq=0;
  for (i=0;i<pg->cesz;i++) { lop(pg->ce,i); 
    if ((i==pathbeg || i==pathidtarg) && qp->inhib) {
      pid(); printf("Checking to or from inhib cell\n" ); hxe(); }
    qp->flag=qp->vinflg=0; 
  }
  hoc_call_func(hoc_lookup("finitialize"), 0);
  cvode_fadvance(1000.0); // this call will not return
  ENDVERBATIM
}

:* paths
: pathgrps(vpre,vpos,vout) finds path lengths from pres to posts
FUNCTION pathgrps () {
  VERBATIM
  int i,j,k,na,nb,flag; double idty,*a,*b,*x,sum; static Point_process *_pnt; static id0 *ip0;
  Symbol* s; char **pfl;
  ip=IDP; pg=ip->pg;
  x=0x0;
  s=hoc_lookup("finitialize");
  if (ifarg(2)) {
    na=vector_arg_px(1,&a);
    nb=vector_arg_px(2,&b);
    if (ifarg(3)) x=vector_newsize(vector_arg(3),na*nb);
  } else {
    na=nb=pg->cesz;  // may want to put output into an unsigned char eventually
    if (ifarg(1)) x=vector_newsize(vector_arg(1),na*nb);
  }
  // if (scrsz<cesz) scrset(cesz); 
  pfl = (char **)malloc(pg->cesz * (unsigned)sizeof(char *));
  for (i=0;i<pg->cesz;i++) { lop(pg->ce,i); scr[i]=qp->inhib; pfl[i]=&qp->flag; }
  pathtytarg=-1;  PATHMEASURE=1; pathlen=stopoq=0;
  for (k=0,sum=0;k<na;k++) {
    pathbeg=a[k]; 
    if (scr[(int)pathbeg]) { 
      if (x) for (j=0;j<nb;j++) x[k*nb+j]=0.;
      continue;
    }
    for (j=0;j<nb;j++) { 
      pathidtarg=b[j]; 
      if (scr[(int)pathidtarg]) { if (x) x[k*nb+j]=0.; 
        continue;
      }
      // for (i=0;i<cesz;i++) {lop(ce,i); qp->flag=0;}
      for (i=0;i<pg->cesz;i++) *pfl[i]=0;
      hoc_call_func(s, 0);
      cvode_fadvance(1000.0); // this call will not return
      sum+=pathlen;
      if (x) x[k*nb+j]=pathlen;
    }
  }
  PATHMEASURE=0;
  free(pfl);
  _lpathgrps=sum/na/nb;
  ENDVERBATIM
}

:* intf.getdvi() get divergence (& optionally associated vectors)
: intf.getdvi(index_vec,delay_vec[,prob_vec,wt1vec,wt2vec,distalsyns,wgain]) -- need both wt1vec and wt2vec
: index = postsynaptic IDs, delay = delay, prob = probability of firing, wt1/wt2 are base weights,
: distalsyns=distal/prox synapse,wgain is multiplier from plasticity/learning
: other forms of this function call:
:  intf.getdvi(getactive.flag,vecs) with flag==1 return types  instead of ids
:  intf.getdvi(getactive.flag,vecs) with flag==2 then sum up number of each type
:  intf.getdvi(getactive.flag,vecs) with flag==3 return column instead of ids
:  with getactive flag ignores pruned connections ie 1.2 is getactive==1 and flag==2
FUNCTION getdvi () {
  VERBATIM 
  {
    int i,j,k,iarg,av1,a2,a3,a4,a6,a7,dvt,getactive=0,idx=0,*pact,prty,poty,sy,ii; 
    double *dbs, *x,*x1,*x2,*x3,*x4,*x5,*x6,*x7,idty,y[2],flag;
    IvocVect* voi, *voi2,*voi3; Point_process **das;
    ip=IDP; pg=ip->pg;
    getactive=a2=a3=a4=0;
    if (ip->dead) return 0.0;
    dvt=ip->dvt; 
    dbs=ip->del;   das=ip->dvi;
    _lgetdvi=(double)dvt; 
    if (!ifarg(1)) return _lgetdvi; // just return the divergence value
    iarg=1;
    if (hoc_is_double_arg(iarg)) {
      av1=2;
      flag=*getarg(iarg++);
      getactive=(int)flag;
      flag-=(double)getactive; // flag is in the decimal place 1.2 has flag of 2
      if (flag!=0) flag=floor(flag*10+hoc_epsilon); // avoid roundoff error
    } else av1=1; // 1st vector arg
    //just get active postsynapses (not dead and non pruned)
    voi=vector_arg(iarg++); 
    if (flag==2) { x1=vector_newsize(voi,CTYPi); for (i=0;i<CTYPi;i++) x1[i]=0;
    } else x1=vector_newsize(voi,dvt);
    if (ifarg(iarg)) { voi=vector_arg(iarg++); x2=vector_newsize(voi,dvt);  a2=1; }
    if (ifarg(iarg)) { voi=vector_arg(iarg++); x3=vector_newsize(voi,dvt); a3=1;}
    if (ifarg(iarg)) { // need 2 weight vecs for AM/NM or GA/GB
      voi=vector_arg(iarg++); x4=vector_newsize(voi,dvt); a4=1;
      voi=vector_arg(iarg++); x5=vector_newsize(voi,dvt);
    }//for prox vs dist syn vec
    if (ifarg(iarg)) { voi=vector_arg(iarg++); x6=vector_newsize(voi,dvt); a6=1;} else a6=0;
    if (ifarg(iarg)) { voi=vector_arg(iarg++); x7=vector_newsize(voi,dvt); a7=1;} else a7=0;//plasticity wgain
    idty=(double)(FOFFSET+ip->id)+1e-2*(double)ip->type+1e-3*(double)ip->inhib+1e-4;
    prty=ip->type; sy=ip->inhib?GA:AM;
    for (i=0,j=0;i<dvt;i++) {
      qp = id0ptr(das[i]->_prop); // #define sop *_ppvar[2].pval
      if (getactive && (qp->dead || ip->sprob[i]==0)) continue;
      if (flag==1) { x1[j]=(double)qp->type; 
      } else if (flag==2) { x1[qp->type]++; 
      } else if (flag==3) { x1[j]=(double)qp->col; 
      } else x1[j]=(double)qp->id;
      if (a2) x2[j]=dbs[i];
      if (a3) x3[j]=(double)ip->sprob[i];
      if (a4) {
        if(ip->inhib){sy=ip->syns[i]?GA2:GA;} else {sy=ip->syns[i]?AM2:AM;} 
        poty = qp->type;
        if (seadsetting==2) { // no randomization
          for(ii=0;ii<2;ii++) y[ii]=WMAT(prty,poty,sy+ii)*WD0(prty,poty,sy+ii);
        } else {
          if (seadsetting==1) { // old sead setting
            sead=(unsigned int)(FOFFSET+ip->id)*qp->id*seedstep; 
          } else { // hashed sead setting
            hsh[0]=(double)(FOFFSET+ip->id); hsh[1]=(double)(qp->id); hsh[2]=seedstep;
            sead=hashseed2(3, hsh);
          }
          mcell_ran4(&sead, y, 2, 1.);
          for(ii=0;ii<2;ii++) {
            y[ii]=2*WVAR*(y[ii]+0.5/WVAR-0.5)*WMAT(prty,poty,sy+ii)*WD0(prty,poty,sy+ii); }
        }
        x4[j]=y[0]; x5[j]=y[1];
      }
      if (a6) x6[j] = ip->syns[i];  // distal / prox syns
      if (a7 && ip->wgain) x7[j] = ip->wgain[i]; // weight gain as from plasticity
      j++;
    }
    if (flag!=2 && j!=dvt) for (i=av1;i<iarg;i++) vector_resize(vector_arg(i),j);
    _lgetdvi=(double)j; 
  }
  ENDVERBATIM
}

: intf.getconv(getactive.flag,vecs) with flag==1 return types instead of ids
: flags getactive.flag flag==2 then sum up number of each type
FUNCTION getconv () {
VERBATIM 
{
  int iarg,i,j,k,dvt,sz,prfl,getactive; double *x,flag;
  IvocVect* voi; Point_process **das; id0 *pp;
  ip=IDP; pg=ip->pg; // this should only be called after jitcondiv()
  sz=ip->dvt; //  // assume conv similar to div
  getactive=0;
  if (ifarg(iarg=1) && hoc_is_double_arg(iarg)) {
    flag=*getarg(iarg++);
    getactive=(int)flag;
    flag-=(double)getactive; // flag is in the decimal place 1.2 has flag of 2
    if (flag!=0) flag=floor(flag*10+hoc_epsilon);
  }
  if (!ifarg(iarg)) prfl=0; else { prfl=1;
    voi=vector_arg(iarg); 
    if (flag==2.) { x=vector_newsize(voi,CTYPi); for (i=0;i<CTYPi;i++) x[i]=0;
    } else x=vector_newsize(voi,sz); 
  } 
  for (i=0,k=0; i<pg->cesz; i++) {
    lop(pg->ce,i);
    if (getactive && qp->dead) continue;
    dvt=qp->dvt; das=qp->dvi;
    for (j=0;j<dvt;j++) {
      if (getactive && qp->sprob[j]==0) continue;
      if (ip == id0ptr(das[j]->_prop)) {
        if (prfl) {
          if (flag!=2.0 && k>=sz) x=vector_newsize(voi,sz*=2);
          if (flag==1.0) { x[k]=(double)qp->type; 
          } else if (flag==2.0) { x[qp->type]++; 
          } else x[k]=(double)qp->id;
        } 
        k++;
        break;
      }
    }
  }
  if (prfl && flag!=2) vector_resize(voi,k);
  _lgetconv=(double)k;
}
ENDVERBATIM
}

: INTF6[0].adjlist(List,[startid,endid,exonly])
: returns adjacency list in first arg
: startid == optional 2nd arg specifies id from which to start
: endid == optional 3rd arg specifies id to end with
: exonly == optional 4th arg specifies to only store excitatory synapse information
FUNCTION adjlist () {
  VERBATIM
  Object* pList = *hoc_objgetarg(1);
  ip=IDP; pg=ip->pg;
  int iListSz=ivoc_list_count(pList),iCell,iStartID=ifarg(2)?*getarg(2):0,\
    iEndID=ifarg(3)?*getarg(3):pg->cesz-1;
  int skipinhib = ifarg(4)?*getarg(4):0, i,j,nv,*pused=(int*)calloc(pg->cesz,sizeof(int)),iSyns=0;
  double **vvo = (double**)malloc(sizeof(double*)*iListSz),\
    *psyns=(double*)calloc(pg->cesz,sizeof(double));
  id0* rp;
  for(iCell=iStartID;iCell<=iEndID;iCell++){
    if(verbose && iCell%1000==0) printf("%d ",iCell);
    lop(pg->ce,iCell);
    if(!qp->dvt || (skipinhib && qp->inhib)){
      list_vector_resize(pList,iCell,0);
      continue;
    }
    iSyns=0;
    for(j=0;j<qp->dvt;j++){      
      rp = id0ptr(qp->dvi[j]->_prop); // #define sop *_ppvar[2].pval
      if(skipinhib && rp->inhib) continue; // if skip inhib cells...
      if(!rp->dead && qp->sprob[j]>0. && !pused[rp->id]){      
        pused[rp->id]=1;
        psyns[iSyns++]=rp->id;
      }
    }
    list_vector_resize(pList, iCell, iSyns);
    list_vector_px(pList, iCell, &vvo[iCell]);
    memcpy(vvo[iCell],psyns,sizeof(double)*iSyns);
    for(j=0;j<iSyns;j++)pused[(int)psyns[j]]=0;
  }
  free(vvo);  free(pused);  free(psyns);
  if (verbose) printf("\n");
  return 1.0;
  ENDVERBATIM
}

FUNCTION rddvi () {
  VERBATIM
  Point_process *pnnt;
  FILE* fp;
  int i, iCell;
  unsigned int iOutID;
  Object* lb;
  fp=hoc_obj_file_arg(1);
  ip=IDP; pg=ip->pg;
  printf("reading: ");
  for(iCell=0;iCell<pg->cesz;iCell++){
    if(iCell%1000==0)printf("%d ",iCell);
    lop(pg->ce,iCell);
    int ret;
    ret = fread(&qp->id,sizeof(unsigned int),1,fp); // read id
    ret = fread(&qp->type,sizeof(unsigned char),1,fp); // read type id
    ret = fread(&qp->col,sizeof(unsigned int),1,fp); // read column id
    ret = fread(&qp->dead,sizeof(unsigned char),1,fp); // read alive/dead status
    ret = fread(&qp->dvt,sizeof(unsigned int),1,fp); // read divergence size
    //free up old pointers
    if(qp->del){ free(qp->del); free(qp->dvi); free(qp->sprob);
      qp->dvt=0; qp->dvi=(Point_process**)0x0; qp->del=(double*)0x0; qp->sprob=(unsigned char *)0x0; }
    //if divergence == 0 , continue
    if(!qp->dvt) continue;
    qp->dvi = (Point_process**)malloc(sizeof(Point_process*)*qp->dvt);  
    for(i=0;i<qp->dvt;i++){
      ret = fread(&iOutID,sizeof(unsigned int),1,fp); // id of output cell
      if (!(lb=ivoc_list_item(pg->ce,iOutID))) {
        printf("INTF6:callback %d exceeds %d for list ce\n",iOutID,pg->cesz); hxe(); }
      qp->dvi[i]=(Point_process *)lb->u.this_pointer;
    }
    qp->del = (double*)malloc(sizeof(double)*qp->dvt);
    ret = fread(qp->del,sizeof(double),qp->dvt,fp); // read divergence delays
    qp->sprob = (unsigned char*)malloc(sizeof(unsigned char)*qp->dvt);
    ret = fread(qp->sprob,sizeof(unsigned char),qp->dvt,fp); // read divergence firing probabilities
  }
  printf("\n");
  return 1.0;
  ENDVERBATIM
}

FUNCTION svdvi () {
  VERBATIM
  Point_process *pnnt;
  FILE* fp;
  int i , iCell;
  fp=hoc_obj_file_arg(1);
  ip=IDP; pg=ip->pg;
  printf("writing: ");
  for(iCell=0;iCell<pg->cesz;iCell++){
    if(iCell%1000==0)printf("%d ",iCell);
    lop(pg->ce,iCell);
    fwrite(&qp->id,sizeof(unsigned int),1,fp); // write id
    fwrite(&qp->type,sizeof(unsigned char),1,fp); // write type id
    fwrite(&qp->col,sizeof(unsigned int),1,fp); // write column id
    fwrite(&qp->dead,sizeof(unsigned char),1,fp); // write alive/dead status
    fwrite(&qp->dvt,sizeof(unsigned int),1,fp); // write divergence size
    if(!qp->dvt)continue; //don't write empty pointers if no divergence
    for(i=0;i<qp->dvt;i++){
      pnnt=qp->dvi[i];
      fwrite(&(id0ptr(pnnt->_prop)->id), sizeof(unsigned int), 1, fp); // id of output cell
    }
    fwrite(qp->del,sizeof(double),qp->dvt,fp); // write divergence delays
    fwrite(qp->sprob,sizeof(unsigned char),qp->dvt,fp); // write divergence firing probabilities
  }
  printf("\n"); 
  return 1.0;
  ENDVERBATIM
}

: INTF6[0].setdvir(wiringlist,delaylist[,flag]) // flag default is 0 to pass to setdvi2()
: INTF6[0].setdvir(wiringlist,delaylist,startid,endid)
: INTF6[0].setdvir(wiringlist,delaylist,startid,endid,flag)
: INTF6[0].setdvir(wiringlist,delaylist,idvec,flag)
: should either use just with flag == 0 to setup all dvi outputs of cells
: or with flag == 1 to incrementally setup outputs from cells and on the last
: set of outputs from a range of cells call with flag == 2 to setup sprob and sort dvi list
: alternatively, can call setdvir with flag == 1, and at end just call INTF6.finishdvir to finalize
FUNCTION setdvir () {
  VERBATIM
  ListVec* pListWires,*pListDels;
  int i,dn,flag,dvt,idvfl,iCell,iStartID,iEndID,nidv,end; 
  double *y, *d, *idvec; unsigned char pdead;
  ip=IDP; pg=ip->pg;
  pListWires = AllocListVec(*hoc_objgetarg(1));
  idvfl=flag=0; iStartID=0; iEndID=pg->cesz-1;
  if(!pListWires){printf("setalldvi ERRA: problem initializing wires list arg!\n"); hxe();}
  pListDels = AllocListVec(*hoc_objgetarg(2));
  if(!pListDels){ printf("setalldvi ERRA: problem initializing delays list arg!\n");
    FreeListVec(&pListWires); hxe(); }
  if (ifarg(3) && !ifarg(4)) { 
    flag=(int)*getarg(3); 
  } else if (hoc_is_double_arg(3)) {
    iStartID=(int)*getarg(3);
    iEndID = (int)*getarg(4);
    if(ifarg(5)) flag=(int)*getarg(5);
  } else {
    nidv=vector_arg_px(3, &idvec);
    idvfl=1;
    if (ifarg(4)) flag=(int)*getarg(4);
  }
  end=idvfl?nidv:(iEndID-iStartID+1);
  for (i=0;i<end;i++) {
    if(i%1000==0) printf("%d",i/1000);
    iCell=idvfl?idvec[i]:(iStartID+i);
    lop(pg->ce,iCell);
    if (qp->dead) continue;
    y=pListWires->pv[i]; dvt=pListWires->plen[i];
    if(!dvt) continue; //skip empty div lists
    d=pListDels->pv[i];  dn=pListDels->plen[i];
    if (dn!=dvt) {printf("setdvir() ERR vec sizes for wire,delay list entries not equal %d: %d %d\n",i,dvt,dn); hxe();}
    setdvi2(y,d,0x0,dvt,flag);
  }
  FreeListVec(&pListWires);
  FreeListVec(&pListDels);
  return 1.0;
  ENDVERBATIM
}

PROCEDURE clrdvi () {
  VERBATIM
  int i;
  ip=IDP; pg=ip->pg;
  for (i=0;i<pg->cesz;i++) { 
    lop(pg->ce,i);
    if (qp->dvt!=0x0) {
      free(qp->dvi); free(qp->del); free(qp->sprob);
      qp->dvt=0; qp->dvi=(Point_process**)0x0; qp->del=(double*)0x0; qp->sprob=(unsigned char *)0x0;
    }
  }
  ENDVERBATIM
}

: int.setdviv(prevec,postvec,delvec)
FUNCTION setdviv () {
  VERBATIM
  int i,j,k,l,nprv,dvt; double *prv,*pov,*dlv,x,*ds; char* s;
  ip=IDP; pg=ip->pg;
  nprv=vector_arg_px(1, &prv);
  i=vector_arg_px(2, &pov);
  j=vector_arg_px(3, &dlv);
  s=0x0;
  if(ifarg(4)) { s=(char*)calloc((l=vector_arg_px(4,&ds)),sizeof(char)); for(k=0;k<l;k++) s[k]=ds[k]; k=0;}
  if (nprv!=i || i!=j) {printf("intf:setdviv ERRA: %d %d %d\n",nprv,i,j); hxe();}
  // start by counting the prids so will know the size that we need for realloc()
  if (scrsz<pg->cesz) scrset(pg->cesz); 
  for (i=0;i<pg->cesz;i++) scr[i]=0;
  for (i=0,j=-1;i<nprv;i++) {
    if (j>(int)prv[i]){printf("intf:setdviv ERRA vecs should be sorted by prid vec\n");hxe();}
    j=(int)prv[i];
    scr[j]++;
  }
  for (i=0,x=-1,k=0;i<nprv;i+=dvt) { if(i%1000==0) printf(".");
    if (prv[i]!=x) lop(pg->ce,(unsigned int)(x=prv[i]));
    if (qp->dead) continue;
    dvt=scr[(int)x]; // number of these presyns
    setdvi2(pov+k,dlv+k,s?s+k:0x0,dvt,1);
    k+=dvt;
  }
  if(s) free(s);
  return (double)k;
  ENDVERBATIM
}

: intf.setsywv(weight vector 1, weight vector 2)
FUNCTION setsywv () {
  VERBATIM
  int sz,n1,n2; double *psyw1,*psyw2; id0* ip;
  ip=IDP; pg=ip->pg; sz=ip->dvt;
  if((n1=vector_arg_px(1, &psyw1))!=sz || (n2=vector_arg_px(2, &psyw2))!=sz) {
    printf("setsywv ERRA: make sure weight vector sizes (%d,%d) same size as div(%d)\n",n1,n2,sz);
    return 0.0;
  }
  if(!ip->syw1) // setup pointers
    ip->syw1=(double*)calloc(sz,sizeof(double)); 
  else ip->syw1=(double*)realloc((double*)ip->syw1,sz*sizeof(double));
  if(!ip->syw2)
    ip->syw2=(double*)calloc(sz,sizeof(double));
  else ip->syw2=(double*)realloc((double*)ip->syw2,sz*sizeof(double));
  memcpy(ip->syw1,psyw1,sizeof(double)*sz); // copy
  memcpy(ip->syw2,psyw2,sizeof(double)*sz);
  return sz;
  ENDVERBATIM
}

: intf.getsywv(weight vector 1, weight vector 2)
FUNCTION getsywv () {
  VERBATIM
  int sz,n1,n2; double *psyw1,*psyw2; id0* ip;
  ip=IDP; pg=ip->pg; sz=ip->dvt;
  if(!ip->syw1 || !ip->syw2) {
    printf("getsywv ERRA: syw1,syw2 were never initialized with setsywv!\n");
    return 0.0;
  }
  if((n1=vector_arg_px(1, &psyw1))!=sz || (n2=vector_arg_px(2, &psyw2))!=sz) {
    printf("getsywv ERRB: make sure weight vector sizes (%d,%d) same size as div(%d)\n",n1,n2,sz);
    return 0.0;
  }
  memcpy(psyw1,ip->syw1,sizeof(double)*sz); // copy
  memcpy(psyw2,ip->syw2,sizeof(double)*sz);
  return sz;
  ENDVERBATIM
}

VERBATIM
// get presynaptic excitatory cells in a double*, psz[0] has size
int* getpeconv (id0* ip,int* psz) {
  Point_process **das; int* pfrom;
  int i,j,k,dvt;
  *psz=ip->dvt; pg=ip->pg;
  pfrom=(int*) calloc(psz[0],sizeof(int));
  for (i=0,k=0; i<pg->cesz; i++) {
    lop(pg->ce,i);
    if(qp->inhib) continue; // skip presynaptic inhib cells
    dvt=qp->dvt;
    das=qp->dvi;
    for (j=0;j<dvt;j++) {
      if (ip == id0ptr(das[j]->_prop)) {
        if (k>=*psz) {
          psz[0]*=2;
          pfrom=(int*) realloc((void*)pfrom,psz[0]*sizeof(int));
        }
        pfrom[k]=qp->id;
        k++;
        break;
      }
    }
  }
  *psz=k;
  return pfrom;
}

int myfindidx (id0* ppre,int poid) {
  int i; Point_process** das; id0* ppo;
  das=ppre->dvi;
  for(i=0;i<ppre->dvt;i++) {
    ppo = id0ptr(das[i]->_prop); // #define sop *_ppvar[2].pval
    if(ppo->id==poid) return i;
  }
  return -1;
}

// apply plasticity
// ppo is postsynaptic cell, pinc is plasticity change, tau is time-constant
// pospkt == time when postsynaptic cell spiked last
// phase is positive for potentiation and negative for depression
static void applyplast (id0* ppo,double pospkt, double phase, double pinc) {
  int poid,prid,sz,i,idx; postgrp* pg; double d,inc,tmp; id0* ppre;
  if(seadsetting!=3. || pinc<=0.) return;
  poid=ppo->id; pg=ppo->pg;
  if(ppo->dbx<-1) printf("applyplast: ppo=%p\n",ppo);
  for(i=0;i<ppo->econvsz;i++) {           // go through presynaptic E cells
    prid = ppo->peconv[i];                // presynaptic id
    if(pg->lastspk[prid]<0) continue;     // cell didn't spike
    d = pospkt - pg->lastspk[prid]; // time difference
    if(d*phase<=0 || fabs(d)>maxplastt) continue; // make sure same phase and within time-constraints
    if(verbose>2) printf("spk%d:%g, spk%d:%g, d=%g\n",prid,pg->lastspk[prid],poid,pg->lastspk[poid],d);
    ppre = getlp(pg->ce,prid);            // get pointer to presynaptic cell
    idx = myfindidx(ppre,poid);           // find the index of poid in ppre's div
    if(idx<0){printf("**** applyplast ERR: bad idx = %d!!!!!!!!!\n",idx); return;}
    inc = pinc; 
    if(d < 0.) inc = -inc; // synaptic depression if post spikes before pre
    tmp = ppre->wgain[idx]; // temp - holds original wgain level
    ppre->wgain[idx] += inc; // increment the wgain of the synapse
    if(ppre->wgain[idx]<0.) ppre->wgain[idx]=0.; // check bounds of wgain
    else if(ppre->wgain[idx]>maxplastw) ppre->wgain[idx]=maxplastw;
    if(verbose>2) printf("%d->%d: inc=%g, wgA=%g, wgB=%g\n",prid,poid,inc,tmp,ppre->wgain[idx]);
  }
}

ENDVERBATIM

: intf.geteconv(vec) - get presynaptic E cell IDs
FUNCTION geteconv () {
  VERBATIM
  int i; double *x; IvocVect *voi;
  ip=IDP; pg=ip->pg;
  if(!ip->peconv) ip->peconv=getpeconv(ip,&ip->econvsz);
  voi=vector_arg(1);
  x=vector_newsize(voi,ip->econvsz);
  for(i=0;i<ip->econvsz;i++) x[i]=(double)ip->peconv[i];
  return ip->econvsz;
  ENDVERBATIM
}

: finishdvi2 () -- finalize dvi , sort dvi , allocate and set sprob
VERBATIM
static void finishdvi2 (struct ID0* p) {
  Point_process **da,**das;
  double *db,*dbs;
  char *syns,*synss;
  int i, dvt;
  db=p->del;
  da=p->dvi; 
  dvt=p->dvt;
  syns=p->syns;
  dbs=(double*)malloc(dvt*sizeof(double)); // sorted delays
  das=(Point_process**)malloc(dvt*sizeof(Point_process*)); // parallel sorted dvi
  synss=(char*)malloc(dvt*sizeof(char)); // sorted syns
  gsort3(db,da,syns,dvt,dbs,das,synss);
  p->del=dbs; p->dvi=das; p->syns=synss;// sorted versions
  free(db); free(da); free(syns);
  p->sprob=(unsigned char*)realloc((void*)p->sprob,(size_t)dvt*sizeof(char));// release probability
  for (i=0;i<dvt;i++) p->sprob[i]=1; // start out with all firing
  p->wgain=(double*)realloc((void*)p->wgain,(size_t)dvt*sizeof(double));//synaptic weight gain
  for (i=0;i<dvt;i++) p->wgain[i]=1.0; // start out at wmat level
  p->peconv = getpeconv(p,&p->econvsz); // get econv
}
ENDVERBATIM

: finalize dvi for all cells
PROCEDURE finishdvir () {
  VERBATIM
  int iCell;
  ip=IDP; pg=ip->pg;
  for(iCell=0;iCell<pg->cesz;iCell++){
    lop(pg->ce,iCell);
    finishdvi2(qp);
  }
  ENDVERBATIM
}

: finishdvi() -- finalize dvi , sort dvi, allocate and set sprob, for this single cell
PROCEDURE finishdvi () {
VERBATIM
  finishdvi2(IDP);
ENDVERBATIM
}

: setdvi(cell#s,dels[,flag]) flag 1: grow internal vecs; flag 2: grow and do final sort
PROCEDURE setdvi () {
VERBATIM {
  int i,j,k,dvt,flag; double *d, *y, *ds; char* s;
  if (! ifarg(1)) {printf("setdvi(v1,v2[,v3,flag]): v1:cell#s; v2:delays; v3:distal synapses\n"); return 0; }
  ip=IDP; pg=ip->pg; // this should only be called after jitcondiv()
  if (ip->dead) return 0;
  dvt=vector_arg_px(1, &y);
  i=vector_arg_px(2, &d);
  s=ifarg(3)?(char*)calloc((j=vector_arg_px(3,&ds)),sizeof(char)):0x0;
  if(s) for(k=0;k<j;k++) s[k]=(char)ds[k];
  if (ifarg(4)) flag=(int)*getarg(4); else flag=0;
  if (i!=dvt || i==0 || (j>0 && j!=i)) {printf("setdvi() ERR vec sizes: %d %d %d\n",dvt,i,j); hxe();}
  setdvi2(y,d,s,dvt,flag);
  }
  return 0;
ENDVERBATIM
}

VERBATIM
// setdvi2(divid_vec,del_vec,syns_vec,div_cnt,flag)
// flag 1 means just augment, 0or2: sort by del, 0: clear lists and replace
static void setdvi2 (double *y,double *d,char* s,int dvt,int flag) {
  int i,j,ddvi; double *db, *dbs; unsigned char pdead; unsigned int b,e; char* syns;
  Object *lb; Point_process *pnnt, **da, **das;
  ddvi=(int)DEAD_DIV;
  ip=IDP; pg=ip->pg;
  if (flag==0) { b=0; e=dvt; // begin to end
    if (ip->dvi) { 
      free(ip->dvi); free(ip->del); free(ip->sprob); free(ip->syns); 
      ip->dvt=0; ip->dvi=(Point_process**)0x0; ip->del=(double*)0x0; ip->sprob=(unsigned char *)0x0; ip->syns=(char*)0x0;
      if(ip->wgain){free(ip->wgain); ip->wgain=0x0;}
      if(ip->peconv){free(ip->peconv); ip->peconv=0x0;}
    } // make sure all null pointers for realloc
  } else { 
    if (ip->dvt==0) {
      ip->dvi=(Point_process**)0x0; ip->del=(double*)0x0; ip->sprob=(unsigned char *)0x0; ip->syns=(char*)0x0;
      ip->wgain=0x0; ip->peconv=0x0;
    }
    b=ip->dvt; 
    e=ip->dvt+dvt; // dvt is amount to grow
  }
  da=(Point_process **)realloc((void*)ip->dvi,(size_t)(e*sizeof(Point_process *)));
  db=(double*)realloc((void*)ip->del,(size_t)(e*sizeof(double)));
  syns=(char*)realloc((void*)ip->syns,(size_t)(e*sizeof(char)));
  for (i=b,j=0;j<dvt;j++) { // i thru da[] j thru y, k to append
    // div can grow at lower rate if dead cells are encountered
    if (!(lb=ivoc_list_item(pg->ce,(unsigned int)y[j]))) {
      printf("INTF6:callback %g exceeds %d for list ce\n",y[j],pg->cesz); hxe(); }
      pnnt=(Point_process *)lb->u.this_pointer;
      if (ddvi==1 || !(pdead = id0ptr(pnnt->_prop)->dead)) {
        da[i]=pnnt; db[i]=d[j]; syns[i]=s?s[j]:0; i++;
      }
  }
  if ((dvt=i)<e) { // will need to shrink these arrays
    da=(Point_process **)realloc((void*)da,(size_t)(e*sizeof(Point_process *)));
    db=(double*)realloc((void*)db,(size_t)(e*sizeof(double)));
    syns=(char*)realloc((void*)syns,(size_t)(e*sizeof(char)));
  }
  ip->dvt=dvt; ip->del=db; ip->dvi=da; ip->syns=syns;
  if (flag!=1) finishdvi2(ip); // do sort
}
ENDVERBATIM

: prune(p[,potype,rand_seed]) // prune synapses with prob p [0,1], ie 0.1 prunes 10% of the divergence
: prune(vec) // fill in the pruning vec with binary values from vec
PROCEDURE prune () {
  VERBATIM 
  {
  id0* ppost; double *x, p; int nx,j,potype;
  ip=IDP; pg=ip->pg;
  if (hoc_is_double_arg(1)) { // prune a certain percent of targets
    p=*getarg(1);
    if (p<0 || p>1) {printf("INTF6:pruneERR0:need # [0,1] to prune [ALL,NONE]: %g\n",p); hxe();}
    if (p==1.) printf("INTF6pruneWARNING: pruning 100%% of cell %d\n",ip->id);
    if (verbose && ip->dvt>dscrsz) {
      printf("INTF6pruneB:Div exceeds dscrsz: %d>%d\n",ip->dvt,dscrsz); hxe(); }
    if (p==0.) {
      for (j=0;j<ip->dvt;j++) ip->sprob[j]=1; // unprune completely
      return 0; // now that unpruning is done, can return
    }
    potype=ifarg(2)?(int)*getarg(2):-1;
    sead=(ifarg(3))?(unsigned int)*getarg(3):GetDVIDSeedVal(ip->id);//seed for divergence and delays
    mcell_ran4(&sead, dscr , ip->dvt, 1.0); // random var (0,1)
    if(potype==-1){ // prune all types of synapses
      for (j=0;j<ip->dvt;j++) if (dscr[j]<p) ip->sprob[j]=0; // prune with prob p
    } else { // only prune synapses with postsynaptic type == potype
      for (j=0;j<ip->dvt;j++){
        ppost = id0ptr(ip->dvi[j]->_prop); // #define sop *_ppvar[2].pval
        if (ppost->type==potype && dscr[j]<p) ip->sprob[j]=0; // prune with prob p
      }
    }
  } else { // confusing arg1==0->sprob[j]=1 for all j; but arg1=[0] (a vector)->sprob[0]=0 
    if (verbose) printf("INTF6 WARNING prune(vec) deprecated: use intf.sprob(vec) instead\n");
    nx=vector_arg_px(1,&x);
    if (nx!=ip->dvt) {printf("INTF6:pruneERRA:Wrong size vector:%d!=%d\n",nx,ip->dvt); hxe();}
    for (j=0;j<ip->dvt;j++) ip->sprob[j]=(unsigned char)x[j];
  }
  }
  return 0;
ENDVERBATIM
}

PROCEDURE sprob () {
  VERBATIM 
  {
  double *x; int nx,j;
  ip=IDP; pg=ip->pg;
  nx=vector_arg_px(1,&x);
  if (nx!=ip->dvt) {printf("INTF6:pruneERRA:Wrong size vector:%d!=%d\n",nx,ip->dvt); hxe();}
  if (ifarg(2)) { // "GET"
    if (!hoc_is_str_arg(2)) { printf("INTF6 sprob()ERRA: only legit 2nd arg is 'GET'\n"); hxe();
    } else for (j=0;j<ip->dvt;j++) x[j]=(double)ip->sprob[j];
  } else {
    for (j=0;j<ip->dvt;j++) ip->sprob[j]=(unsigned char)x[j];
  }
  }
ENDVERBATIM
}

: turnoff(v1,v2) turn off any connection from a cell in v1 to a cell with number in v2
: a global call that can be called from any INTF6
PROCEDURE turnoff () {
  VERBATIM {
  int nx,ny,i,j,k,dvt; double poid,*x,*y; Point_process **das; unsigned char off;
  ip=IDP; pg=ip->pg;
  nx=vector_arg_px(1,&x);
  ny=vector_arg_px(2,&y);
  if (ifarg(3)) off=(unsigned char)*getarg(3); else off=0;
  for (i=0;i<nx;i++) { 
    lop(pg->ce,(unsigned int)x[i]); 
    dvt=qp->dvt; das=qp->dvi;
    for (j=0;j<dvt;j++) {
      ip = id0ptr(das[j]->_prop); // sop is *_ppvar[2].pval
      poid=(double)ip->id; // postsyn id
      for (k=0;k<ny;k++) {
        if (poid==y[k]) {
          qp->sprob[j]=off; break;
        }
      }
    }
  }
  }
  ENDVERBATIM
}

VERBATIM 
// gsort2() sorts 2 parallel vectors -- delays and Point_process pointers
void gsort2 (double *db, Point_process **da,int dvt,double *dbs, Point_process **das) {
  int i;
  scr=scrset(dvt);
  for (i=0;i<dvt;i++) scr[i]=i;
  nrn_mlh_gsort(db, (int*)scr, dvt, cmpdfn);
  for (i=0;i<dvt;i++) {
    dbs[i]=db[scr[i]];
    das[i]=da[scr[i]];
  }
}
// gsort3() sorts 3 parallel vectors -- delays and Point_process pointers
void gsort3 (double *db, Point_process **da,char* syns,int dvt,double *dbs, Point_process **das,char* synss) {
  int i;
  scr=scrset(dvt);
  for (i=0;i<dvt;i++) scr[i]=i;
  nrn_mlh_gsort(db, (int*)scr, dvt, cmpdfn);//sorts indices in scr
  for (i=0;i<dvt;i++) {
    dbs[i]=db[scr[i]];
    das[i]=da[scr[i]];
    synss[i]=syns[scr[i]];
  }
}
ENDVERBATIM

PROCEDURE freedvi () {
  VERBATIM
  { 
    int i, poty; id0 *jp;
    jp=IDP;
    if (jp->dvi) {
      free(jp->dvi); free(jp->del); free(jp->sprob); free(jp->syns);
      if(jp->wgain){free(jp->wgain); jp->wgain=0x0;}
      if(jp->peconv){free(jp->peconv); jp->peconv=0x0;}
      jp->dvt=0; jp->dvi=(Point_process**)0x0; jp->del=(double*)0x0; jp->sprob=(unsigned char *)0x0; jp->syns=(char *)0x0;
    }
  }
  ENDVERBATIM
}

FUNCTION qstats () {
  VERBATIM {
    double stt[3]; int lct,flag; FILE* tfo;
    if (ifarg(1)) {tfo=hoc_obj_file_arg(1); flag=1;} else flag=0;
    lct=cty[IDP->type];
    _lqstats = nrn_event_queue_stats(stt);
    printf("SPIKES: %d (%ld:%ld)\n",IDP->spkcnt,spikes[lct],blockcnt[lct]);
    printf("QUEUE: Inserted %g; removed %g\n",stt[0],stt[2]);
    if (flag) {
      fprintf(tfo,"SPIKES: %d (%ld:%ld);",IDP->spkcnt,spikes[lct],blockcnt[lct]);
      fprintf(tfo,"QUEUE: Inserted %g; removed %g remaining: %g\n",stt[0],stt[2],_lqstats);
    }
  }
  ENDVERBATIM
}

FUNCTION qsz () {
  VERBATIM {
    double stt[3];
    _lqsz = nrn_event_queue_stats(stt);
  }
  ENDVERBATIM
}

PROCEDURE qclr () {
  VERBATIM {
    clear_event_queue();
  }
  ENDVERBATIM
}

: mywmat(from,to,synapse) - return WMAT value from mod side
FUNCTION mywmat () {
  VERBATIM {
  int i,j,k;
  i=(int)*getarg(1);
  if(i<0 || i>=CTYPi){printf("mywmat ERR: arg 1=%d out of bounds (0,%d]\n",i,CTYPi); return -1;}
  j = (int)*getarg(2);
  if(j<0 || j>=CTYPi){printf("mywmat ERR: arg 2=%d out of bounds (0,%d]\n",j,CTYPi); return -1;}
  k = (int)*getarg(3);
  if(k<0 || k>=STYPi){printf("mywmat ERR: arg3=%d out of bounds (0,%d]\n",k,STYPi); return -1;}
  return WMAT(i,j,k);
  }
  ENDVERBATIM  
}

: mywmatpr - print out WMAT from mod side
PROCEDURE mywmatpr () {
  VERBATIM {
  double wm;
  int i,j,k;
  char *ct1,*ct2;
  ip=IDP; pg=ip->pg;
  for(i=0;i<CTYPi;i++) if(ctt(i,&ct1)!=0) {
    for(j=0;j<CTYPi;j++) if(ctt(j,&ct2)!=0) {
      for(k=0;k<STYPi;k++) {
        if((wm=WMAT(i,j,k))>0) {
          printf("wmat[%s][%s][%d]=%g\n",ct1,ct2,k,wm);
        }
      }      
    }
  }
  }
  ENDVERBATIM
}


: intf.jitcondiv() assigns pointers for hoc symbol storage
PROCEDURE jitcondiv () {
  VERBATIM {
  Symbol *sym; int i,j; unsigned int sz,colid; char *name;

  pg=(postgrp *)calloc(1,sizeof(postgrp));
  colid = (int)*getarg(2);

  if(ppg==0x0) { // initial allocation
    ippgbufsz = 5;
    ppg = (postgrp**) calloc(ippgbufsz,sizeof(postgrp*));
    inumcols = 1;
  } else inumcols++;

  if(colid >= ippgbufsz) { // need more memory? then realloc
    ippgbufsz *= 2;
    ppg = (postgrp**) realloc((void*)ppg,(size_t)ippgbufsz*sizeof(postgrp*));
  }
  ppg[colid] = pg;
  pg->col = colid;
  pg->ce =  *hoc_objgetarg(1);

  sym = hoc_lookup("CTYP"); 
  CTYP = (*(hoc_objectdata[sym->u.oboff].pobj));

  if (installed==2.0) { // jitcondiv was previously run
    sz=ivoc_list_count(pg->ce);
    if (sz==pg->cesz && colid==0) printf("\t**** INTF6 WARNING cesz unchanged: INTF6(s) created off-list ****\n");
  } else installed=2.0;
  pg->cesz = ivoc_list_count(pg->ce); if(verbose) printf("cesz=%d\n",pg->cesz);
  pg->lastspk = (double*)calloc(pg->cesz,sizeof(double)); // last spike time of each cell

  // not column specific
  CTYPi=HVAL("CTYPi"); STYPi=HVAL("STYPi"); dscrsz=HVAL("scrsz"); dscr=HPTR("scr");

  // column specific
  pg->ix = hoc_pgetarg(3);
  pg->ixe = hoc_pgetarg(4);

  if(verbose){printf("CTYPi=%d\n",CTYPi);
    for(i=0;i<CTYPi;i++) printf("ix[%d]=%g, ixe[%d]=%g\n",i,pg->ix[i],i,pg->ixe[i]);}

  pg->dvg = hoc_pgetarg(5); // div
  pg->numc = hoc_pgetarg(6); // numc
  pg->wmat = hoc_pgetarg(7); // wmat
  pg->wd0 = hoc_pgetarg(8); // wd0
  pg->delm = hoc_pgetarg(9); // delm
  pg->deld = hoc_pgetarg(10); // deld

  if (!pg->ce) {printf("INTF6 jitcondiv ERRA: ce not found\n"); hxe();}
  if (ivoc_list_count(CTYP)!=CTYPi){
    printf("INTF6 jitcondiv ERRB: %d %d\n",ivoc_list_count(CTYP),CTYPi); hxe(); }
  for (i=0;i<pg->cesz;i++) { lop(pg->ce,i); qp->pg=pg; } // set all of the pg pointers for now
  // make sure no seg error:
  printf("Checking for possible seg error in double arrays: CTYPi==%d: ",CTYPi);
  // can access arbitrary member dvg[a][b] using (&dvg[a*CTYPi])[b] or dvg+a*CTYPi+b
  printf("%d %d %d ",DVG(CTYPi-1,CTYPi-1),(int)pg->ix[CTYPi-1],(int)pg->ixe[CTYPi-1]);
  printf("%g %g ",WMAT(CTYPi-1,CTYPi-1,STYPi-1),WD0(CTYPi-1,CTYPi-1,STYPi-1));
  printf("%g %g ",DELM(CTYPi-1,CTYPi-1),DELD(CTYPi-1,CTYPi-1));
  printf("%d %g\n",dscrsz,dscr[dscrsz-1]); // scratch area for doubles
  for (i=0,j=0;i<CTYPi;i++) if (ctt(i,&name)!=0) {
    cty[j]=i; CNAME[j]=name; ctymap[i]=j;
    j++;
    if (j>=CTYPp) {printf("jitcondiv() INTERRA\n"); hxe();}
  }
  CTYN=j; // number of cell types being used
  for (i=0;i<CTYN;i++) printf("%s(%d)=%g ",CNAME[i],cty[i],NUMC(cty[i]));
  printf("\n%d cell types being used in col %d\n",CTYN,colid);
  }
  ENDVERBATIM  
}

: intf.jitrec(vec,tvec)
PROCEDURE jitrec () {
  VERBATIM {
  int i;
  ip=IDP; pg=ip->pg;
  if(verbose>1) printf("jitrec from col %d, ip=%p, pg=%p\n",ip->col,ip,pg);
  if (! ifarg(2)) { // clear with jitrec() or jitrec(0)
    pg->jrmax=0; pg->jridv=0x0; pg->jrtvv=0x0;
    return 0;
  }
  i =   vector_arg_px(1, &pg->jrid); // could just set up the pointers once
  pg->jrmax=vector_arg_px(2, &pg->jrtv);
  pg->jridv=vector_arg(1); pg->jrtvv=vector_arg(2);
  pg->jrmax=vector_buffer_size(pg->jridv);
  if (pg->jrmax!=vector_buffer_size(pg->jrtvv)) {
    printf("jitrec() ERRA: not same size: %d %d\n",i,pg->jrmax); pg->jrmax=0; hxe(); }
  pg->jri=pg->jrj=0; // needs to be set at beginning of run
  }
  return 0;
  ENDVERBATIM
}

: intf.scsv()
FUNCTION scsv () {
  VERBATIM {
  int ty=4; int i,j; unsigned int cnt=0;
  ip=IDP; pg=ip->pg;
  name = gargstr(1);
  if ( !(wf1 = fopen(name,"w"))) { printf("Can't open %s\n",name); hxe(); }
  fwrite(&pg->cesz,sizeof(int),1,wf1);
  fwrite(&ty,sizeof(int),1,wf1);
  for (i=0,j=0;i<pg->cesz;i++,j++) { 
    lop(pg->ce,i); 
    if (qp->spkcnt) {
      dscr[j]=(double)(qp->spkcnt); 
      cnt++;
    } else dscr[j]=0.0;
    if (j>=dscrsz) {
      fwrite(dscr,(size_t)sizeof(double),(size_t)dscrsz,wf1);
      fflush(wf1);
      j=0;
    }
  }
  if (j>0) fwrite(dscr,(size_t)sizeof(double),(size_t)j,wf1);
  fclose(wf1);
  _lscsv=(double)cnt;
  }
  ENDVERBATIM
}

: intf.spkcnt(vec[,vec,flag])
: intf.spkcnt(min,max[,vec,flag]) flag=1 means reset all counts to 0
FUNCTION spkcnt () {
  VERBATIM {
  int nx, ny, i,j, ix, c, min, max, flag; unsigned int sum; double *y,*x;
  ip=IDP; pg=ip->pg;
  nx=ny=min=max=flag=0; i=1;
  if (ifarg(i)) {
    if (hoc_is_object_arg(i)) { 
      ny = vector_arg_px(i, &y); i++;
    } else if (ifarg(i+1)) {
      min=(int)*getarg(i); max=(int)*getarg(i+1); i+=2;
    }
  }
  while (ifarg(i)) { // can pick up flag and vector in either order
    if (hoc_is_object_arg(i)) { // output to a vector
      nx = vector_arg_px(i, &x);
    } else flag=(int)*getarg(i);
    i++;
  }
  if (ny) max=ny; else if (max==0) max=pg->cesz; else max+=1; // enter max index wish to graph
  if (nx && nx!=max-min) {
    printf("INTF6 spkcnt() ERR: Vectors not same size %d %d\n",nx,max-min);hxe();}
  for  (i=min, sum=0;i<max;i++) { 
    if (ny) lop(pg->ce,(int)y[i]); else lop(pg->ce,i);
    if (flag==2) sum+=(c=qp->blkcnt); else sum+=(c=qp->spkcnt);
    if (nx) x[i]=(double)c;
    if (flag==1) qp->spkcnt=qp->blkcnt=0;
  }
  _lspkcnt=(double)sum;
  }
  ENDVERBATIM
}

:** probejcd()
PROCEDURE probejcd () {
  VERBATIM {  int i,a[4];
    ip=IDP; pg=ip->pg;
    for (i=1;i<=3;i++) a[i]=(int)*getarg(i);
    printf("CTYPi: %d, STYPi: %d, ",CTYPi,STYPi);
    // printf("div: %d, ix: %d, ixe: %d, ",DVG(a[1],a[2]),(int)ix[a[1]],(int)ixe[a[1]]);
    printf("wmat: %g, wd0: %g\n",WMAT(a[1],a[2],a[3]),WD0(a[1],a[2],a[3]));
  }
  ENDVERBATIM  
}

:** randspk() sets next to next val in vector, this vector is handled globally
PROCEDURE randspk () {
  VERBATIM 
  ip=IDP; pg=ip->pg;
  if (ip->rvi > ip->rve) { // pointers go from rvi to rve inclusive
    ip->input=0;           // turn off
    nxt=-1.;
  } else if (t==0) {     // initialization
    nxt=pg->vsp[ip->rvi];
    EXSY=pg->sysp[ip->rvi]; // synapse target for external input
    WEX=pg->wsp[ip->rvi++]; // weight of external input
  } else {     // absolute times in vector -> interval
    while ((nxt=pg->vsp[ip->rvi++]-t)<=1e-6) { 
      if (ip->rvi-1 > ip->rve) { printf("randspk() ERRA: "); chk(2.); hxe(); }
    }
    EXSY=pg->sysp[ip->rvi-1]; // rvi was incremented
    WEX=pg->wsp[ip->rvi-1]; // rvi was incremented    
  }
  ENDVERBATIM
  : net_send(nxt,2) : can only be called from INITIAL or NET_RECEIVE blocks
}

:** vers gives version
PROCEDURE vers () {
  printf("$Id: intf6.mod,v 1.58 2011/02/04 05:39:43 samn Exp $\n")
}

:** val(t,tstart) fills global vii[] to pass values back to record() (called from record())
VERBATIM
void val (double xx, double ta) { 
  vii[1]=VAM*EXP(-(xx - ta)/tauAM);
  vii[2]=VNM*EXP(-(xx - ta)/tauNM);
  vii[3]=VGA*EXP(-(xx - ta)/tauGA);

  vii[5]=AHP*EXP(-(xx - ta)/tauahp);
  vii[8]=VAM2*EXP(-(xx -ta)/tauAM2);
  vii[9]=VNM2*EXP(-(xx - ta)/tauNM2);
  vii[10]=VGA2*EXP(-(xx - ta)/tauGA2);
  vii[6]=vii[1]+vii[2]+vii[3]+vii[4]+vii[5]+vii[8]+vii[9]+vii[10];
  vii[7]=VTH + (VTHR-VTH)*EXP(-(xx-trrs)/tauRR);
}
ENDVERBATIM

:** valps(t,tstart) like val but builds voltages for pop spike
VERBATIM
void valps (double xx, double ta) { 
  vii[1]=VAM*EXP(-(xx - ta)/tauAM);
  vii[2]=VNM*EXP(-(xx - ta)/tauNM);
  vii[3]=VGA*EXP(-(xx - ta)/tauGA);

  vii[8]=VAM2*EXP(-(xx - ta)/tauAM2);
  vii[9]=VNM2*EXP(-(xx - ta)/tauNM2);
  vii[10]=VGA2*EXP(-(xx - ta)/tauGA2);
  vii[6]=vii[1]+vii[2]-vii[3]+vii[8]+vii[9]-vii[10];
}
ENDVERBATIM

:** record() stores values since last tg into appropriate vecs
PROCEDURE record () {
  VERBATIM {
  int i,j,k,nz; double ti;
  vp = SOP;
  if(!vp) {printf("**** record ERRA: vp=NULL!\n"); return 0;}
  if (tg>=t) return 0;
  if (ip->record==1) {
    while ((int)vp->p >= (int)vp->size-(int)((t-tg)/vdt)-10) { 
      vp->size*=2;
      for (k=0;k<NSV;k++) if (vp->vv[k]!=0x0) vp->vvo[k]=vector_newsize(vp->vv[k], vp->size);
      // printf("**** WARNING expanding recording room to %d (type%d id%d at %g)****\n",vp->size,IDP->type,IDP->id,t);
    }
  } else if ((int)vp->p > (int)vp->size-(int)((t-tg)/vdt)) { // shift if record==2
    nz=(int)((t-tg)/vdt);
    for (k=0;k<NSV;k++) if (vp->vv[k]!=0x0) {
      if (nz>vp->size) {pid(); printf("Record WARNING: vec too short: %d %d\n",nz,vp->size);
        vp->p=0;
      } else {
        for (i=nz,j=0; i<vp->size; i++,j++) vp->vvo[k][j]=vp->vvo[k][i];
        vp->p=vp->size-nz;
      }
    }
  }
  for (ti=tg;ti<=t && vp->p < vp->size;ti+=vdt,vp->p++) { 
    val(ti,tg);  
    if (vp->vvo[0]!=0x0) vp->vvo[0][vp->p]=ti;
    for (k=1;k<NSV-1;k++) if (vp->vvo[k]!=0x0) { // not nil pointer
      vp->vvo[k][vp->p]=vii[k]+RMP;
    }
    for (;k<NSV;k++) if (vp->vvo[k]!=0x0) { // not nil pointer
      vp->vvo[k][vp->p]=vii[k]; 
    }
  }
  tg=t;
  }
  ENDVERBATIM
}

:** recspk() records a spike by writing a 10 into the main VM vector
PROCEDURE recspk (x) {
  VERBATIM { int k;
  vp = SOP;
  record();
  if (vp->p > vp->size || vp->vvo[6]==0) return 0; 
  if (vp->vvo[0]!=0x0) vp->vvo[0][vp->p-1]=_lx;
  vp->vvo[6][vp->p-1]=spkht; // the spike
  tg=_lx;
  }
  ENDVERBATIM
}

:** recclr() clear the vectors pointers
PROCEDURE recclr () {
  VERBATIM 
  {int k;
  if (IDP->record) {
    if (SOP!=nil) {
      vp = SOP;
      vp->size=0; vp->p=0;
      for (k=0;k<NSV;k++) { vp->vv[k]=nil; vp->vvo[k]=nil; }
    } else printf("INTF6 recclr ERR: nil pointer\n");
  }
  IDP->record=0;
  }
  ENDVERBATIM 
}

:** recfree() free the vpt pointer memory
PROCEDURE recfree () {
  VERBATIM
  if (SOP!=nil) {
    free(SOP);
    SOP=nil;
  } else printf("INTF6 recfree ERR: nil pointer\n");
  IDP->record=0;
  ENDVERBATIM
}

:** initvspks() sets up vector from which to read random spike times 
: this is a global procedure to set up pieces of a global vector
: all cells share one vector but read from different locations
: (CHANGED from intervals and global proc in v224)
: intf.initvspks(indices, times , weights, synapse types)
PROCEDURE initvspks () {
  VERBATIM 
  {int max, i,err;
    double last,lstt;
    ip=IDP; pg=ip->pg;
    if (! ifarg(1)) {printf("Return initvspks(ivspks,vspks,wvspks)\n"); return 0.;}
    if(verbose>1) printf("initvspks: col=%d, ip=%p, pg=%p, pg->isp=%p\n",ip->col,ip,pg,pg->isp);
    if (pg->isp!=NULL) clrvspks();
    ip=IDP; pg=ip->pg; err=0;
    i = vector_arg_px(1, &pg->isp); // could just set up the pointers once
    max=vector_arg_px(2, &pg->vsp);
    if (max!=i) {err=1; printf("initvspks ERR: vecs of different size\n");}
    if (max==0) {err=1; printf("initvspks ERR: vec not initialized\n");}
    max=vector_arg_px(3, &pg->wsp);
    if (max!=i) {err=1; printf("initvspks ERR: 3rd vec is of different size\n");}
    max=vector_arg_px(4, &pg->sysp);
    if (max!=i) {err=1; printf("initvspks ERR: 4th vec is of different size\n");}
    pg->vspn=max;
    if (!pg->ce) {printf("Need global ce for initvspks() since intf.mod501\n"); hxe();}
    for (i=0,last=-1; i<max; ) { // move forward to first
      if (pg->isp[i]!=last) { // new one
        lop(pg->ce,(unsigned int)pg->isp[i]);
        qp->rvb=qp->rvi=i;
        qp->vinflg=1;
        last=pg->isp[i];
        lstt=pg->vsp[i];
        i++;
      }
      for (; i<max && pg->isp[i] == last; i++) { // move forward to last
        if (pg->vsp[i]<=lstt) { err=1; 
          printf("initvspks ERR: nonmonotonic for cell#%d: %g %g\n",qp->id,lstt,pg->vsp[i]); }
          lstt=pg->vsp[i];
      }
      qp->rve=i-1;
      if (subsvint>0) { 
        pg->vsp[qp->rve] = pg->vsp[qp->rvb]+subsvint;
        pg->wsp[qp->rve] = pg->wsp[qp->rvb];
      }
      if (err) { qp->rve=0; hxe(); }
    }
  }
  ENDVERBATIM
}

:** shock() reads random spike times from save db as initvspks() but just sends a single shock
: to each listed cell
: this is a global procedure that calls multiple cells
PROCEDURE shock () {
  VERBATIM 
  {int max, i,err;
    double last, lstt, *isp, *vsp, *wsp;
    if (! ifarg(1)) {printf("Return shock(ivspks,vspks,wvspks)\n"); return 0.;}
    ip=IDP; pg=ip->pg; err=0;
    i = vector_arg_px(1, &isp); // could just set up the pointers once
    max=vector_arg_px(2, &vsp);
    if (max!=i) {err=1; printf("shock ERR: vecs of different size\n");}
    if (max==0) {err=1; printf("shock ERR: vec not initialized\n");}
    max=vector_arg_px(3, &wsp);
    if (max!=i) {err=1; printf("shock ERR: 3rd vec is of different size\n");}
    pg->vspn=max;
    if (!pg->ce) {printf("Need global ce for shock()\n"); hxe();}
    for (i=0,last=-1; i<max; ) { // move forward to first
      if (isp[i]!=last) { // skip any redund indices
        lop(pg->ce,(unsigned int)isp[i]);
        WEX=-1e9; // code for shock
        EXSY=AM;  // set to AMPA, though doesn't matter for single shock
  #if defined(t)
        net_send((void**)0x0, wts,pmt,t+vsp[i],2.0); // 2 is randspk flag
  #else
        net_send((void**)0x0, wts,pmt,vsp[i],2.0); // 2 is randspk flag
  #endif
        i++;
      }
    }
  }
  ENDVERBATIM
}

PROCEDURE clrvspks () {
 VERBATIM {
 unsigned int i;
 ip=IDP; pg=ip->pg;
 if(verbose>1) printf("clrvspks: col=%d, ip=%p, pg=%p, pg->isp=%p\n",ip->col,ip,pg,pg->isp);
 for (i=0; i<pg->cesz; i++) {
   lop(pg->ce,i);
   qp->vinflg=0;
 }   
 }
 ENDVERBATIM
}

: trvsp gets called globally to go through the vector
: first pass (arg 1) it replaces terminal values with 1e9
: second pass (arg 2) it replaces terminal values with first+subsvint
PROCEDURE trvsp ()
{
  VERBATIM 
  int i, flag; 
  double ind, local_t0;
  ip=IDP; pg=ip->pg;
  flag=(int) *getarg(1);
  if (subsvint==0.) {printf("trvsp"); return(0.);}
  ind = pg->isp[0];
  local_t0 = pg->vsp[0];
  if (flag==1) {
    for (i=0; i<pg->vspn; i++) {
      if (pg->isp[i]!=ind) {
        pg->vsp[i-1]=1.e9;
        ind=pg->isp[i];
      }
    }
    pg->vsp[pg->vspn-1]=1.e9;
  } else if (flag==2) {
    for (i=0; i<pg->vspn; i++) {
      if (pg->isp[i]!=ind) {
        pg->vsp[i-1] = local_t0 + subsvint;
        ind=pg->isp[i];
        local_t0 = pg->vsp[i];
      }
    }
    pg->vsp[pg->vspn-1] = local_t0 + subsvint;
  } else {printf("trvsp flag %d not recognized\n",flag); hxe();}
  ENDVERBATIM
}

:** initjttr() sets up vector from which to read jitter 
: -- key jtt to avoid confusion with jitcon=='just in time connection'
: this is a global not a range procedure -- just call once
PROCEDURE initjttr () {
  VERBATIM 
  {int max, i, err=0;
    ip=IDP; pg=ip->pg;
    pg->jtpt=0;
    if (! ifarg(1)) {printf("Return initjttr(vec)\n"); return(0.);}
    max=vector_arg_px(1, &jsp);
    if (max==0) {err=1; printf("initjttr ERR: vec not initialized\n");}
    for (i=0; i<max; i++) if (jsp[i]<=0) {err=1;
      printf("initjttr ERR: vec should be >0: %g\n",jsp[i]);}
    if (err) { jsp=nil; pg->jtmax=0.; return(0.); }// hoc_execerror("",0);
    if (max != pg->jtmax) {
      printf("WARNING: resetting jtmax_INTF6 to %d\n",max); pg->jtmax=max; }
  }
  ENDVERBATIM
}

:* internal routines
VERBATIM

//** getlp(LIST,ITEM#) sets qp: take object from ob list @ index i and return pointer
// modeled on vector_arg_px(): picks up obj from list and resolves pointers
id0* getlp (Object *ob, unsigned int i) {
  Object *lb; id0* myp;
  lb = ivoc_list_item(ob, i);
  if (! lb) { printf("INTF6:getlp %d exceeds %d for list ce\n",i,pg->cesz); hxe();}
  pmt=ob2pntproc(lb);
  myp = id0ptr(pmt->_prop); // #define sop *_ppvar[2].pval
  return myp;
}
//** lop(LIST,ITEM#) sets qp: take object from ob list @ index i and assign pointer to GLOBAL qp pointer
// modeled on vector_arg_px(): picks up obj from list and resolves pointers
static void lop (Object *ob, unsigned int i) {
  Object *lb;
  lb = ivoc_list_item(ob, i);
  if (! lb) { printf("INTF6:lop %d exceeds %d for list ce\n",i,pg->cesz); hxe();}
  pmt=ob2pntproc(lb);
  qp = id0ptr(pmt->_prop); // #define sop *_ppvar[2].pval
}

// use stoppo() as a convenient conditional breakpoint in gdb (gdb watching is too slow)
void stoppo () {
}

//** ctt(ITEM#) find cells that exist by name
static int ctt (unsigned int i, char** name) {
  Object *lb;
  if (NUMC(i)==0) return 0; // none of this cell type
  lb = ivoc_list_item(CTYP, i);
  if (! lb) { printf("INTF6:ctt %d exceeds %d for list CTYP\n",i,CTYPi); hxe();}
  {*name=*(lb->u.dataspace->ppstr);}
  return (int)NUMC(i);
}
ENDVERBATIM


PROCEDURE test () {
  VERBATIM
  char *str; int x;
  x=ctt(7,&str); 
  printf("%s (%d)\n",str,x);
  ENDVERBATIM
}

: lof can find object information
PROCEDURE lof () {
VERBATIM {
  Object *ob; int num,i,ii,j,k,si,nx;  double *vvo[7], *par; IvocVect *vv[7];
  ob = *(hoc_objgetarg(1));
  si=(int)*getarg(2);
  num = ivoc_list_count(ob);
  if (num!=7) { printf("INTF6 lof ERR %d>7\n",num); hxe(); }
  for (i=0;i<num;i++) { 
    j = list_vector_px3(ob, i, &vvo[i], &vv[i]);
    if (i==0) nx=j;
    if (j!=nx) { printf("INTF6 lof ERR %d %d\n",j,nx); hxe(); }
  }
  //  for (i=ix[si],ii=0;i<=ixe[si] && ii<nx;i++,ii++) {
  //   vvo[0][ii]=(double)i;
  //   par=lop(ce,i);
  //   for (j=20,k=1;j<25;j++,k++) { // NB these could move: Vm,VAM,VNM,VGA
  //     vvo[k][ii]=par[j];
  //   }
  // }
 }
ENDVERBATIM
}

:* initinvl() sets up vector from which to read intervals
: this is a global not a range procedure -- just call once
PROCEDURE initinvl () {
  printf("initinvl() NOT BEING USED\n")
}

: invlflag() used internally; can't set from here; use initinvl() and range invlset()
FUNCTION invlflag () {
  VERBATIM
  ip=IDP; pg=ip->pg;
  if (ip->invl0==1 && invlp==nil) { // err
    printf("INTF6 invlflag ERR: pointer not initialized\n"); hoc_execerror("",0); 
  }
  _linvlflag= (double)ip->invl0;
  ENDVERBATIM
}

:** shift() returns the appropriate shift
FUNCTION shift (vl) { 
  VERBATIM   
  double expand, tmp, min, max;
//if (invlp==nil) {printf("INTF6 invlflag ERRa: pointer not initialized\n"); hoc_execerror("",0);}
  if ((t<(invlt-invl)+invl/2) && invlt != -1) { // don't shift if less than halfway through
    _lshift=0.;  // flag for no shift
  } else {
    expand = -(_lvl-(-65))/20; // expand positive if hyperpolarized
    if (expand>1.) expand=1.; if (expand<-1.) expand=-1.;
    if (expand>0.) { // expand interval
      max=1.5*invl;
      tmp=oinvl+0.8*expand*(max-oinvl); // the amount we can add to the invl
    } else {
      min=0.5*invl; 
      tmp=oinvl+0.8*expand*(oinvl-min); // the amount we can reduce current invl
    }
    if (invlt+tmp<t+2) { // getting too near spike time
      _lshift=0.;
    } else {
      oinvl=tmp; // new interval
      _lshift=invlt+oinvl;
    }
  }
  ENDVERBATIM
}

:* recini() called from INITIAL block to set vp->p to zero and open up vectors
PROCEDURE recini () {
  VERBATIM 
  { int k;
  if (SOP==nil) { 
    printf("INTF6 record ERR: pointer not initialized\n"); hoc_execerror("",0); 
  } else {
    vp = SOP;
    vp->p=0;
    // open up the vector maximally before writing into it; will correct size in fini
    for (k=0;k<NSV;k++) if (vp->vvo[k]!=0) vector_resize(vp->vv[k], vp->size);
  }}
  ENDVERBATIM
}

:** fini() to finish up recording -- should be called from FinishMisc()
PROCEDURE fini () {
  VERBATIM 
  {int k;
  // initialization for next round, this will not be set if job terminates prematurely
  IDP->rvi=IDP->rvb;  // -- see vinset()
  if (IDP->wrec) { wrecord(1e9); }
  if (IDP->record) {
    record(); // finish up
    for (k=0;k<NSV;k++) if (vp->vvo[k]!=0) { // not nil pointer
      vector_resize(vp->vv[k], vp->p);
    }
  }}
  ENDVERBATIM
}

:** chk([flag]) with flag=1 prints out info on the record structure
:                    flag=2 prints out info on the global vectors
PROCEDURE chk (f) {
  VERBATIM 
  {int i,lfg;
  lfg=(int)_lf;
  ip=IDP; pg=ip->pg;
  printf("ID:%d; typ: %d; rec:%d wrec:%d inp:%d jtt:%d invl:%d\n",ip->id,ip->type,ip->record,ip->wrec,ip->input,ip->jttr,ip->invl0);
  if (lfg==1) {
    if (SOP!=nil) {
      vp = SOP;
      printf("p %d size %d tg %g\n",vp->p,vp->size,tg);
      for (i=0;i<NSV;i++) if (vp->vv[i]) printf("%d %p %p;",i,vp->vv[i],vp->vvo[i]);
    } else printf("Recording pointers not initialized");
  }
  if (lfg==2) { 
    printf("Global vectors for input and jitter (jttr): \n");
    if (pg->vsp!=nil) printf("VSP: %p (%d/%d-%d)\n",pg->vsp,ip->rvi,ip->rvb,ip->rve); else printf("no VSP\n");
    if (jsp!=nil) printf("JSP: %p (%d/%d)\n",jsp,pg->jtpt,pg->jtmax); else printf("no JSP\n");
  }
  if (lfg==3) { 
    if (pg->vsp!=nil) { printf("VSP: (%d/%d-%d)\n",ip->rvi,ip->rvb,ip->rve); 
      for (i=ip->rvb;i<=ip->rve;i++) printf("%d:%g  ",i,pg->vsp[i]);
      printf("\n");
    } else printf("no VSP\n");
  }
  if (lfg==4) {  // was used to give invlp[],invlmax
  }
  if (lfg==5) { 
    printf("wwpt %d wwsz %d\n WW vecs: ",wwpt,wwsz);
    printf("wwwid %g wwht %d nsw %g\n WW vecs: ",wwwid,(int)wwht,nsw);
    for (i=0;i<NSW;i++) printf("%d %p %p;",i,ww[i],wwo[i]);
  }}
  ENDVERBATIM
}

:** id() and pid() identify the cell -- printf and function return
FUNCTION pid () {
  VERBATIM 
  printf("INTF6%d(%d/%d@%g) ",IDP->id,IDP->type,IDP->col,t);
  _lpid = (double)IDP->id;
  ENDVERBATIM
}

: intra-column identifier for cell
FUNCTION id () {
  VERBATIM
  if (ifarg(1)) IDP->id = (unsigned int) *getarg(1);
  _lid = (double)IDP->id;
  ENDVERBATIM
}

FUNCTION type () {
  VERBATIM
  if (ifarg(1)) IDP->type = (unsigned char) *getarg(1);
  _ltype = (double)IDP->type;
  ENDVERBATIM
}

: column identifier for cell
FUNCTION col () {
  VERBATIM 
  ip = IDP; 
  if (ifarg(1)) ip->col = (unsigned int) *getarg(1);
  _lcol = (double)ip->col;
  ENDVERBATIM
}

: global identifier for cell
FUNCTION gid () {
  VERBATIM 
  ip = IDP; 
  if (ifarg(1)) ip->gid = (unsigned int) *getarg(1);
  _lgid = (double)ip->gid;
  ENDVERBATIM
}

FUNCTION dbx () {
  VERBATIM 
  ip = IDP; 
  if (ifarg(1)) ip->dbx = (unsigned char) *getarg(1);
  _ldbx = (double)ip->dbx;
  ENDVERBATIM
}

:** initrec(name,vec) sets up recording of name (see varnum for list) into a vector
PROCEDURE initrec () {
  VERBATIM 
  {int i;
  name = gargstr(1);
  if (SOP==nil) { 
    IDP->record=1;
    SOP = (vpt*)ecalloc(1, sizeof(vpt));
    SOP->size=0;
  }
  if (IDP->record==0) {
    recini();
    IDP->record=1;
  }
  vp = SOP;
  i=(int)varnum();
  if (i==-1) {printf("INTF6 record ERR %s not recognized\n",name); hoc_execerror("",0); }
  vp->vv[i]=vector_arg(2);
  vector_arg_px(2, &(vp->vvo[i]));
  if (vp->size==0) { vp->size=(unsigned int)vector_buffer_size(vp->vv[i]);
  } else if (vp->size != (unsigned int)vector_buffer_size(vp->vv[i])) {
    printf("INTF6 initrec ERR vectors not all same size: %d vs %d",vp->size,vector_buffer_size(vp->vv[i]));
    hoc_execerror("", 0); 
  }} 
  ENDVERBATIM
}

:** varnum(statevar_name) returns index number associated with particular variable name
: called by initrec() using global name
FUNCTION varnum () { LOCAL i
  i=-1
  VERBATIM
  if (strcmp(name,"time")==0)      { _li=0.;
  } else if (strcmp(name,"VAM")==0) { _li=1.;
  } else if (strcmp(name,"VNM")==0) { _li=2.;
  } else if (strcmp(name,"VGA")==0) { _li=3.;
  } else if (strcmp(name,"AHP")==0) { _li=5.;
  } else if (strcmp(name,"V")==0) { _li=6.;
  } else if (strcmp(name,"VM")==0) { _li=6.; // 2 names for V
  } else if (strcmp(name,"VTHC")==0) { _li=7.;
  } else if (strcmp(name,"VAM2")==0) { _li=8.;
  } else if (strcmp(name,"VNM2")==0) { _li=9.;
  } else if (strcmp(name,"VGA2")==0) { _li=10.;
  }
  ENDVERBATIM
  varnum=i
}

:** vecname(INDEX) prints name when given an index
PROCEDURE vecname () {
  VERBATIM
  int i; 
  i = (int)*getarg(1);
  if (i==0)      printf("time\n");
  else if (i==1) printf("VAM\n");
  else if (i==2) printf("VNM\n");
  else if (i==3) printf("VGA\n");
  else if (i==5) printf("AHP\n");
  else if (i==6) printf("V\n");
  else if (i==7) printf("VTHC\n");
  else if (i==8) printf("VAM2\n");
  else if (i==9) printf("VNM2\n");
  else if (i==10) printf("VGA2\n");
  ENDVERBATIM
}

:** initwrec(name,vec) sets up recording of sim field potential
PROCEDURE initwrec () {
  VERBATIM 
  {int i, k, num, cap;  Object* ob;
    ob =   *hoc_objgetarg(1); // list of vectors
    num = ivoc_list_count(ob);
    if (num>NSW) { printf("INTF6 initwrec() WARN: can only store %d ww vecs\n",NSW); hxe();}
    nsw=(double)num;
    for (k=0;k<num;k++) {
      cap = list_vector_px2(ob, k, &wwo[k], &ww[k]);
      if (k==0) wwsz=cap; else if (wwsz!=cap) {
        printf("INTF6 initwrec ERR w-vecs size err: %d,%d,%d",k,wwsz,cap); hxe(); }
    }
  }
  ENDVERBATIM
}

: popspk() is paste on gaussian for a pop spk: with vdt=0.1 -20 to 20 is 4 ms
: needs to be above location where is actively accessed
PROCEDURE popspk (x) {
  TABLE Psk DEPEND wwwid,wwht FROM -40 TO 40 WITH 81
  Psk = -wwht*exp(-2.*x*x/wwwid/wwwid)
}

PROCEDURE pskshowtable () {
  VERBATIM 
  int j;
  printf("_tmin_popspk:%g -_tmin_popspk:%g\n",_tmin_popspk,-_tmin_popspk);
  for (j=0;j<=-2*(int)_tmin_popspk+1;j++) printf("%g ",_t_Psk[j]);
  printf("\n");
  ENDVERBATIM 
}

:** wrecord() records voltages onto single global vector
PROCEDURE wrecord (te) {
  VERBATIM 
  {int i,j,k,max,wrp; double ti,scale;
  for (i=0;i<WRNUM && (wrp=(int)IDP->wreci[i])>-1;i++) {
    // wrp: index for multiple field recordings
    scale=(double)IDP->wscale[i];
    if (_lte<1.e9) { // a spike recording
      if (scale>0) {
        max=-(int)_tmin_popspk; // max of table max=-min
        k=(int)floor((_lte-rebeg)/vdt+0.5);
        for (j= -max;j<=max && k+j>0 && k+j<wwsz;j++) {
          wwo[wrp][k+j] += scale*_t_Psk[j+max]; // direct copy from the Psk table
        }
      }
    } else if (twg>=t) { return 0;
    } else {
      for (ti=twg,k=(int)floor((twg-rebeg)/vdt+0.5);ti<=t && k<wwsz;ti+=vdt,k++) { 
        valps(ti,twg);  // valps() for pop spike calculation
        wwo[wrp][k]+=vii[6]*lfpscale;
        if (IDP->dbx==-1) printf("%g:%g ",vii[6],wwo[wrp][k]);
      }
    }
  }
  if (_lte==1.e9) twg=ti;
  }
  return 0;
  ENDVERBATIM
}

: backward compatibility -- note that index was 1-offset; convert to 0 offset here
: wrec() -- return value in wrec0
: wrec(VAL) -- set wrec0
: wrec(VAL,SCALE) -- set wrecIND and scaling for wrecIND
FUNCTION wrec () {
  VERBATIM
  { int k,ix;
  ip=IDP; 
  if (ifarg(1)) {
    ix=(int)*getarg(1);
    if (ix>=1) {
      if (ix-1>=nsw) {
        printf("Attempt to save into ww[%d] but only have %d\n",ix-1,(int)nsw); hxe();}
      ip->wrec=1;
      ip->wreci[0]=(char)ix-1;
      ip->wscale[0]=1.; // default
      if (ifarg(2)) ip->wscale[0]= (float)*getarg(2); 
    } else if (ix<=0) {
      ip->wrec=0;
      for (k=0;k<WRNUM;k++) { ip->wreci[k]=-1; ip->wscale[k]=-1.0; }
    } else {printf("INTF6 wrec ERR flag(0/1) %d\n",ip->wrec); hxe();
    }
  }
  _lwrec=(double)ip->wrec;
  }
  ENDVERBATIM
}

: wrc() -- return value in wrec0
: wrc(VAL) -- set wrec0
: wrc(IND,SCALE) -- set wrec0 and scaling for wrec0
FUNCTION wrc () {
  VERBATIM
  { int i,ix;
  ip=IDP; 
  if (ifarg(1)) {  // 1 or 2 args
    ix=(int)*getarg(1);
    if (ix<0) {
      ip->wrec=0;
      for (i=0;i<WRNUM;i++) { ip->wreci[i]=-1; ip->wscale[i]=-1.0; }
    } else {
      for (i=0;i<WRNUM && ip->wreci[i]!=-1 && ip->wreci[i]!=ix;i++) {};
      if (i==WRNUM) {
        pid(); printf("INFT wrc() ERR: out of wreci pointers (max %d)\n",WRNUM); hxe();}
      if (ix>=nsw) {printf("Attempt to save into ww[%d] but only have %d\n",ix,(int)nsw); hxe();}
      ip->wrec=1; 
      ip->wreci[i]=ix;
      if (ifarg(2)) ip->wscale[i]=(float)*getarg(2); else ip->wscale[i]=1.0;
    }
  } else {
    for (i=0;i<WRNUM;i++) printf("%d:%g ",ip->wreci[i],ip->wscale[i]);
    printf("\n");
  }
  _lwrc=(double)ip->wrec;
  }
  ENDVERBATIM
}

FUNCTION wwszset () {
  VERBATIM
  if (ifarg(1)) wwsz = (unsigned int) *getarg(1);
  _lwwszset=(double)wwsz;
  ENDVERBATIM
}

:** wwfree()
FUNCTION wwfree () {
  VERBATIM
  int k;
  IDP->wrec=0;
  wwsz=0; wwpt=0; nsw=0.;
  for (k=0;k<NSW;k++) { ww[k]=nil; wwo[k]=nil; }
  ENDVERBATIM
}

:** jttr() reads out of a noise vector (call from NET_RECEIVE block)
FUNCTION jttr () {
  VERBATIM 
  ip=IDP; pg=ip->pg;
  if (pg->jtmax>0 && pg->jtpt>=pg->jtmax) {  
    pg->jtpt=0;
    printf("Warning, cycling through jttr vector at t=%g\n",t);
  }
  if (pg->jtmax>0) _ljttr = jsp[pg->jtpt++]; else _ljttr=0;
  ENDVERBATIM
}

:** global_init() initialize globals shared by all INTF6s
PROCEDURE global_init () {
  popspk(0) : recreate table if any change in wid or ht
  VERBATIM 
  { int i,j,k,c; double stt[3];
  if (nsw>0. && wwo[0]!=0) { // do just once
    printf("Initializing ww to record for %g (%g)\n",vdt*wwsz,vdt);
    wwpt=0;
    for (k=0;k<(int)nsw;k++) {
      vector_resize(ww[k], wwsz);
      for (j=0;j<wwsz;j++) wwo[k][j]=0.;
    }
  }
  errflag=0;
  for (i=0;i<CTYN;i++) blockcnt[cty[i]]=spikes[cty[i]]=0;
  for(c=0;c<inumcols;c++) {
    pg=ppg[c]; if(!pg) continue;
    if (pg->jridv) { pg->jri=pg->jrj=0; vector_resize(pg->jridv, pg->jrmax); vector_resize(pg->jrtvv, pg->jrmax); }
    pg->spktot=0;
    pg->jtpt=0;
    pg->eventtot=0;
  }
  }
  ENDVERBATIM
}

PROCEDURE global_fini () {
  VERBATIM
  int c,k;
  for (k=0;k<(int)nsw;k++) vector_resize(ww[k], (int)floor(t/vdt+0.5));
  for(c=0;c<inumcols;c++) {
    pg=ppg[c]; if(!pg) continue;
    if (pg->jridv && pg->jrj<pg->jrmax) {
      vector_resize(pg->jridv, pg->jrj); 
      vector_resize(pg->jrtvv, pg->jrj);
    }
  }
  ENDVERBATIM
}

:* setting and getting flags: fflag, record,input,jttr
FUNCTION fflag () { fflag=1 }
FUNCTION thrh () { thrh=VTH-RMP }
: reflag() used internally; can't set from here; use recinit()
FUNCTION recflag () { 
  VERBATIM
  _lrecflag= (double)IDP->record;
  ENDVERBATIM
}

: vinflag() used internally; can't set from here; use global initvspks() and range vinset()
FUNCTION vinflag () {
  VERBATIM
  ip=IDP; pg=ip->pg;
  if (ip->vinflg==0 && pg->vsp==nil) { // do nothing
  } else if (ip->vinflg==1 && ip->rve==-1) {
    printf("INTF6 vinflag ERR: pointer not initialized\n"); hoc_execerror("",0); 
  } else if (ip->rve >= 0) { 
    if (pg->vsp==nil) {
      printf("INTF6 vinflag ERR1: pointer not initialized\n"); hoc_execerror("",0); 
    }
    ip->rvi=ip->rvb;
    ip->input=1;
  }
  _lvinflag= (double)ip->vinflg;
  ENDVERBATIM
}

:** flag(name,[val,setall]) set or get a flag
:   flag(name,vec) fill vec with flag value from all the cells
: seek names from iflags[] and look at location &ip->type -- beginning of flags
FUNCTION flag () {
  VERBATIM
  char *sf; static int ix,fi,setfl,nx; static unsigned char val; static double *x, delt;
  ip=IDP; pg=ip->pg;
  if (FLAG==OK) { // callback -- DO NOT SET FROM HOC
    FLAG=0.;
    if (stoprun) {slowset=0; return 0.0;}
    if (IDP->dbx==-1)printf("slowset fi:%d ix:%d ss:%g delt:%g t:%g\n",fi,ix,slowset,delt,t);
    if (t>slowset || ix>=pg->cesz) {  // done
      printf("Slow-setting of flag %d finished at %g: (%d,%g,%g)\n",fi,t,ix,delt,slowset); 
      slowset=0.; return 0.0;
    }
    if (ix<pg->cesz) {
      lop(pg->ce,ix);
      (&qp->type)[fi]=((fi>=iflneg)?(char)x[ix]:(unsigned char)x[ix]);
      ix++;
      #if defined(t)
      net_send((void**)0x0, wts,tpnt,t+delt,OK); // OK is flag() flag
      #else
      net_send((void**)0x0, wts,tpnt,delt,OK);
      #endif
    }
    return 0.0;
  }  
  if (slowset>0 && ifarg(3)) {
    printf("INTF6 flag() slowset ERR; attempted set during slowset: fi:%d ix:%d ss:%g delt:%g t:%g",\
           fi,ix,slowset,delt,t); 
    return 0.0;
  }
  ip = IDP; setfl=ifarg(3); 
  if (ifarg(4)) { slowset=*getarg(4); delt=slowset/pg->cesz; slowset+=t; } 
  sf = gargstr(1);
  for (fi=0;fi<iflnum && strncmp(sf, &iflags[fi*4], 3)!=0;fi++) ; // find flag by name
  if (fi==iflnum) {printf("INTF6 ERR: %s not found as a flag (%s)\n",sf,iflags); hxe();}
  if (ifarg(2)) {
    if (hoc_is_double_arg(2)) {  // either set to all or just to this one
      val=(unsigned char)*getarg(2);
      if (slowset) { // set one and come back
        printf("NOT IMPLEMENTED\n"); // ****NOT IMPLEMENTED****
      } else if (setfl) { // set them all
        for (ix=0;ix<pg->cesz;ix++) { lop(pg->ce,ix); (&qp->type)[fi]=val; }
      } else {  // just set this one
        (&ip->type)[fi]=((fi>=iflneg)?(char)val:val);
      }
    } else {
      nx=vector_arg_px(2,&x);
      if (nx!=pg->cesz) {
        if (setfl) { printf("INTF6 flag ERR: vec sz mismatch: %d %d\n",nx,pg->cesz); hxe();
        } else       x=vector_newsize(vector_arg(2),pg->cesz);
      }
      if (setfl && slowset) { // set one and come back
        ix=0;
        lop(pg->ce,ix);
        (&qp->type)[fi]=((fi>=iflneg)?(char)x[ix]:(unsigned char)x[ix]);
        ix++;
        #if defined(t)
        net_send((void**)0x0, wts,tpnt,t+delt,OK); // OK is flag() flag
        #else
        net_send((void**)0x0, wts,tpnt,delt,OK);
        #endif
      } else for (ix=0;ix<pg->cesz;ix++) { 
        lop(pg->ce,ix); 
        if (setfl) { (&qp->type)[fi]=((fi>=iflneg)?(char)x[ix]:(unsigned char)x[ix]);
        } else {
          x[ix]=(double)((fi>=iflneg)?(char)(&qp->type)[fi]:(unsigned char)(&qp->type)[fi]);
        }
      }
    }
  }
  _lflag=(double)((fi>=iflneg)?(char)(&ip->type)[fi]:(unsigned char)(&ip->type)[fi]);
  ENDVERBATIM
}

FUNCTION allspck () {
  VERBATIM
  int i; double *x, sum; IvocVect *voi;
  ip = IDP; pg=ip->pg;
  voi=vector_arg(1);  x=vector_newsize(voi,pg->cesz);
  for (i=0,sum=0;i<pg->cesz;i++) { lop(pg->ce,i); 
    x[i]=spck;
    sum+=spck;
  }
  _lallspck=sum;
  ENDVERBATIM
}

:** resetall()
PROCEDURE resetall () {
  VERBATIM
  int ii,i; unsigned char val;
  ip=IDP; pg=ip->pg;
  if(verbose>1) printf("resetall: ip=%p, col=%d, pg=%p\n",ip,pg->col,pg);
  for (i=0;i<pg->cesz;i++) { 
    lop(pg->ce,i);
    Vm=RMP; VAM=0; VNM=0; VGA=0; AHP=0; invlt=-1; VAM2=0; VNM2=0; VGA2=0;
    t0=t; trrs=t; twg = t; cbur=0; spck=0; refractory=0; VTHC=VTHR=VTH; 
  }
  ENDVERBATIM
}

:** floc(x,y[,z]) // find a cell by location
FUNCTION floc () {
  VERBATIM
  double x,y,z,r,min,rad, *ix; int ii,i,n,cnt; IvocVect* voi;
  cnt=0; n=1000; r=-1;
  ip = IDP; pg=ip->pg;
  x = *getarg(1);
  y = *getarg(2);
  z= ifarg(3)?(*getarg(3)):1e9;
  if (ifarg(5)) {
    r= *getarg(4);
    voi=vector_arg(5);
    ix=vector_newsize(voi,n);
  } 
  for (i=0,min=1e9,ii=-1;i<pg->cesz;i++) { 
    lop(pg->ce,i); 
    rad=(x-xloc)*(x-xloc)+(y-yloc)*(y-yloc)+(z==1e9?0.:((z-zloc)*(z-zloc))); // rad^2
    if (r>0 && rad<r*r) {
      if (cnt>=n) ix=vector_newsize(voi,n*=2);
      ix[cnt]=(double)i;
      cnt++;
    }
    if (rad<min) { min=rad; ii=i; }
  }
  if (r>0) ix=vector_newsize(voi,cnt);
  _lfloc=(double)ii;
  ENDVERBATIM
}

:** invlset([val]) set or get the invl flag
FUNCTION invlset () {
  VERBATIM
  ip=IDP;
  if (ifarg(1)) ip->invl0 = (unsigned char) *getarg(1);
  _linvlset=(double)ip->invl0;
  ENDVERBATIM
}

:** vinset([val]) set or get the input flag (for using shared input from a vector)
FUNCTION vinset () {
  VERBATIM
  ip=IDP;
  if (ifarg(1)) ip->vinflg = (unsigned char) *getarg(1);
  if (ip->vinflg==1) {
    ip->input=1;
    ip->rvi = ip->rvb;
  }
  _lvinset=(double)ip->vinflg;
  ENDVERBATIM
}

:* TABLES
PROCEDURE EXPo (x) {
  TABLE RES FROM -20 TO 0 WITH 5000
  RES = exp(x)
}

FUNCTION EXP (x) {
  EXPo(x)
  EXP = RES
}

PROCEDURE ESINo (x) {
  TABLE ESIN FROM 0 TO 2*PI WITH 3000 : one cycle
  ESIN = sin(x)
}

FUNCTION rates (vv) {
  : from Stevens & Jahr 1990a,b
  rates = maxnmc / (1 + exp(0.062 (/mV) * -vv) * ( (mg / mg0) ) )
}

