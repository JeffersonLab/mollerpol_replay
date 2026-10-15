#include "TSystem.h"
#include "TTree.h"
#include "TList.h"
#include "THaRun.h"
#include "THaEvent.h"
#include "THaAnalyzer.h"
#include "THaApparatus.h"
#include "MollerPolHelicityDecoderBoard.h"
#include "MollerPolApparatus.h"
#include "MollerPolCalorimeter.h"
#include "MollerPolScalerEvtHandler.h"
#include "MollerPolHelicityDecoder.h"


void replay(int run_number, int seg = 0, UInt_t nevents=-1,
	    UInt_t first_event = 0, UInt_t last_event = 0){

  gSystem->Load("libMollerPol");

  MollerPolApparatus *mol = new MollerPolApparatus("M", "Moller polarimeter apparatus");
  gHaApps->Add(mol);
  //MollerPolHelicityDecoderBoard *heldec = new MollerPolHelicityDecoderBoard("heldecoder", "Helicity Decoder Module");
  MollerPolHelicityDecoder *heldec = new MollerPolHelicityDecoder("heldecoder", "Helicity Decoder Module");
  heldec->SetDebug(0);
  mol->AddDetector(heldec);
  
  // Set up the analyzer - we use the standard one,
  // but this could be an experiment-specific one as well.
  // The Analyzer controls the reading of the data, executes
  // tests/cuts, loops over Apparatus's and PhysicsModules,
  // and executes the output routines.
  THaAnalyzer* analyzer = new THaAnalyzer;
  
  // Add event handler for scaler events
  MollerPolScalerEvtHandler* scaler = new MollerPolScalerEvtHandler("M", "scaler event type 1");
  scaler->AddEvtType(1);
  gHaEvtHandlers->Add(scaler);
  //scaler->SetDebugFile("DebugScaler.txt");
  
  // A simple event class to be output to the resulting tree.
  // Creating your own descendant of THaEvent is one way of
  // defining and controlling the output.
  THaEvent* event = new THaEvent;

  // Define the run(s) that we want to analyze.
  // We just set up one, but this could be many.
  THaRun* run = new THaRun(Form("/hamoller/data/raw/mollerpol_test_%d.evio.%d",run_number,seg) );

  run->SetFirstEvent(first_event);
  run->SetLastEvent((UInt_t)(last_event > first_event ? last_event : nevents+first_event));

  run->SetDataRequired(1);
  run->SetDate(TDatime());

  analyzer->SetVerbosity(4);
  analyzer->SetOdefFile("replay.odef");
  // Define the analysis parameters
  analyzer->SetEvent( event );
  //analyzer->SetOutFile( Form("%s/fadcV2_moller_analyzer_%d.%d.root", gSystem->Getenv("HAMOLLER_ROOTFILE_DIR"),run_number,seg) );
  analyzer->SetOutFile( Form("%s/fadcV2_moller_analyzer_%d.%d.root", "/hamoller/data/Rootfiles",run_number,seg) );
  TTree::SetMaxTreeSize(2000000000);//2GB TFile size
  // File to record cuts accounting information
  analyzer->SetSummaryFile( Form("%s/summary_%d.log", gSystem->Getenv("HAMOLLER_SUMMARY_DIR"),run_number) ); // optional
  analyzer->EnableHelicity(true);
  // Print out progress every nth event
  int n = 100000;
  analyzer->SetMarkInterval(n);
  //analyzer->SetCompressionLevel(0); // turn off compression
  analyzer->Process(run);     // start the actual analysis
}
