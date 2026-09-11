--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;
with Flyology_Bench.Internal_Conditions;
with Flyology_Bench.Internal_Condition_Test_Hooks;
with Flyology_Bench.Internal_Probes;
with Interfaces;

procedure Flyology_Bench.Internal_Condition_Integration_Smoke is
   package Hooks renames Flyology_Bench.Internal_Condition_Test_Hooks;
   use type Internal_Probes.Host_System;
   use type Interfaces.Unsigned_64;

   Calls           : Natural := 0
   with Volatile;
   Work            : Natural := 0
   with Volatile;
   Tests_Directory : constant String :=
     Ada.Directories.Containing_Directory
       (Ada.Directories.Containing_Directory
          (Ada.Directories.Containing_Directory (Ada.Command_Line.Command_Name)));
   Fixture_Root    : constant String := Tests_Directory & "/fixtures/linux_conditions/";

   procedure Batch (Iterations : Iteration_Count) is
   begin
      Calls := Calls + Natural (Iterations);
      for Iteration in Iteration_Count range 1 .. Iterations loop
         pragma Unreferenced (Iteration);
         --  Maximum_Iterations stays at one so recollection call counts are
         --  exact. Keep that one iteration longer than a coarse timer tick.
         for Spin in 1 .. 1_024 loop
            pragma Unreferenced (Spin);
            Work := Work + 1;
         end loop;
      end loop;
   end Batch;

   procedure Benchmark is new Measure_Batched (Batch);
   procedure Pair_Benchmark is new Compare_Batched (Batch, Batch);

   type Test_Case is (First_Case, Second_Case);

   procedure Multi_Batch (Which : Test_Case; Iterations : Iteration_Count) is
      pragma Unreferenced (Which);
   begin
      Batch (Iterations);
   end Multi_Batch;

   procedure Multi_Benchmark is new Compare_Many (Test_Case, Multi_Batch);

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   procedure Read_Linux_Fixture
     (Name                      : String;
      PPD_Profile               : String;
      PPD_Profile_Available     : Boolean;
      PPD_Degradation           : String;
      PPD_Degradation_Available : Boolean;
      Value                     : out Internal_Conditions.Snapshot;
      Continuity                : in out Internal_Conditions.Throttle_Continuity) is
   begin
      Hooks.Reset;
      Hooks.Use_Linux_Fixture
        (Fixture_Root & Name, PPD_Profile, PPD_Profile_Available, PPD_Degradation, PPD_Degradation_Available);
      Internal_Conditions.Read (Value, Continuity);
   end Read_Linux_Fixture;

   function Policy
     (Policy_Mode : Operating_Conditions_Mode;
      Window      : Positive_Duration := 0.010) return Operating_Conditions_Policy
   is
   begin
      case Policy_Mode is
         when Disabled =>
            return Disabled_Operating_Conditions;

         when Observe =>
            return
              Observe
                (Require_Nonreduced_Profile => True,
                 Require_Profile_Detection  => True,
                 Maximum_Thermal_State      => Thermal_State_Fair,
                 Require_Thermal_Detection  => True,
                 Window                     => Window);

         when Fail    =>
            return
              Fail
                (Require_Nonreduced_Profile => True,
                 Require_Profile_Detection  => True,
                 Maximum_Thermal_State      => Thermal_State_Fair,
                 Require_Thermal_Detection  => True,
                 Window                     => Window);

         when Pause   =>
            raise Program_Error;
      end case;
   end Policy;

   function Policy
     (Policy_Mode        : Operating_Conditions_Mode;
      On_Pause_Timeout   : Condition_Pause_Fallback;
      Window             : Positive_Duration := 0.010;
      Stable_Time        : Positive_Duration := 0.001;
      Poll_Interval      : Positive_Duration := 0.001;
      Maximum_Pause_Time : Positive_Duration := 0.100) return Operating_Conditions_Policy
   is
   begin
      if Policy_Mode /= Pause then
         raise Program_Error;
      end if;
      return
        Pause
          (On_Pause_Timeout           => On_Pause_Timeout,
           Require_Nonreduced_Profile => True,
           Require_Profile_Detection  => True,
           Maximum_Thermal_State      => Thermal_State_Fair,
           Require_Thermal_Detection  => True,
           Window                     => Window,
           Stable_Time                => Stable_Time,
           Poll_Interval              => Poll_Interval,
           Maximum_Pause_Time         => Maximum_Pause_Time,
           Rewarm_Time                => 0.0);
   end Policy;

   --  GNAT 15 crashes when this boxed conditional value is nested inside the
   --  enclosing delta aggregate. Give it a type before building Config.
   function Test_Interference (Enabled : Boolean) return Interference_Policy
   is (if Enabled
       then
         (Enabled                     => True,
          Response                    => Observe,
          Maximum_Foreign_CPU_Percent => 100.0,
          Window                      => 0.001,
          others                      => <>)
       else (others => <>));

   --  GNAT 13 and 14 require inner parentheses around delta aggregates in
   --  expression functions.
   function Config
     (Policy_Mode  : Operating_Conditions_Mode;
      Interference : Boolean := False) return Configuration
   is ((Default_Configuration
       with delta
         Warmup_Time          => 0.0,
         Measurement_Time     => 0.000_100,
         Samples              => 10,
         Minimum_Sample_Time  => 0.000_001,
         Maximum_Iterations   => 1,
         Subtract_Timer_Cost  => False,
         Bootstrap_Resamples  => 100,
         Metrics              => Time_Metrics,
         Interference         => Test_Interference (Interference),
         Operating_Conditions => Policy (Policy_Mode)));

   function Config
     (Policy_Mode      : Operating_Conditions_Mode;
      On_Pause_Timeout : Condition_Pause_Fallback;
      Interference     : Boolean := False) return Configuration
   is ((Default_Configuration
       with delta
         Warmup_Time          => 0.0,
         Measurement_Time     => 0.000_100,
         Samples              => 10,
         Minimum_Sample_Time  => 0.000_001,
         Maximum_Iterations   => 1,
         Subtract_Timer_Cost  => False,
         Bootstrap_Resamples  => 100,
         Metrics              => Time_Metrics,
         Interference         => Test_Interference (Interference),
         Operating_Conditions => Policy (Policy_Mode, On_Pause_Timeout)));

   procedure Check_Multi_Recollection (Schedule : Shootout_Schedule_Policy) is
      Test_Config    : constant Configuration :=
        (Config (Pause, Fallback_Observe) with delta Shootout_Scheduling => Schedule);
      Observe_Config : constant Configuration :=
        (Config (Observe) with delta Shootout_Scheduling => Schedule);
      --  The baseline and recollection are sequential, so keep only one
      --  full-capacity result live while Compare_Many uses its call frame.
      Result         : Multi_Comparison;
      Baseline_Calls : Natural;
   begin
      Hooks.Reset;
      Calls := 0;
      Multi_Benchmark (Observe_Config, Result);
      Baseline_Calls := Calls;

      Hooks.Reset;
      Hooks.Reject_Read (6);
      Calls := 0;
      declare
         First_Result   : Measurement;
         Second_Result  : Measurement;
         First_Report   : Environment_Report;
         Second_Report  : Environment_Report;
         Expected_Rerun : constant Natural := (if Schedule = Balanced_Rounds then 20 else 10);
      begin
         Multi_Benchmark (Test_Config, Result);
         First_Result := Case_Measurement (Result, 1);
         Second_Result := Case_Measurement (Result, 2);
         First_Report := Environment (First_Result);
         Second_Report := Environment (Second_Result);
         Check
           (Cases (Result) = 2
            and then Samples (First_Result) = 10
            and then Samples (Second_Result) = 10
            and then Shootout_Schedule (Result) = Schedule,
            "multi-way recollection changed retained cases, samples, or schedule");
         Check
           (First_Report.Condition_Pauses = 1
            and then First_Report.Affected_Units = 10
            and then First_Report.Recollected_Units = 10
            and then Second_Report.Condition_Pauses = 1
            and then Second_Report.Affected_Units = 10
            and then Second_Report.Recollected_Units = 10,
            "multi-way recollection report was not copied to every case");
         Check
           (Calls >= Baseline_Calls + Expected_Rerun,
            "multi-way comparison reported recollection without rerunning its window");
      end;
   end Check_Multi_Recollection;

begin
   Check (Hooks.Enabled, "condition integration smoke selected disabled hooks");

   declare
      Exact      : constant String (1 .. 32 * 1_024) := (others => 'x');
      Oversized  : constant String (1 .. 32 * 1_024 + 1) := (others => 'x');
      Continuity : Internal_Conditions.Throttle_Continuity;
      Value      : Internal_Conditions.Snapshot;
      Success    : Boolean;
      Length     : Natural;

      procedure Capture (Command : String; Argument : String; Timeout_MS : Positive) is
      begin
         Hooks.Reset;
         Hooks.Use_Capture_Test (Command, Argument, Timeout_MS);
         Internal_Conditions.Read (Value, Continuity);
         Hooks.Capture_Test_Result (Success, Length);
      end Capture;
   begin
      Capture ("/usr/bin/printf", Exact, 1_000);
      Check (Success and then Length = Exact'Length, "exact-capacity output was rejected");
      Capture ("/usr/bin/printf", Oversized, 1_000);
      Check (not Success and then Length = 0, "oversized output was accepted");
      Capture ("/bin/sleep", "2", 10);
      Check (not Success and then Length = 0, "command deadline was ignored");
   end;

   --  Run the real Linux detector against committed sysfs fixtures on every
   --  host. The enabled hook supplies raw paths and PPD values; normal Read
   --  still performs all parsing, aggregation, selection, and continuity.
   declare
      Continuity : Internal_Conditions.Throttle_Continuity;
      Value      : Internal_Conditions.Snapshot;
   begin
      Read_Linux_Fixture ("aggregate", "", False, "", False, Value, Continuity);
      Check
        (Value.Throttle_Availability = Condition_Available
         and then Value.Throttle_Time_Avail = Condition_Available
         and then Value.Throttle_Total = 15
         and then Value.Throttle_Time_Total_MS = 150,
         "Linux throttle fixture did not deduplicate sibling CPUs and package counters");
      Check
        (not Value.Throttle_Discontinuous and then not Value.Throttle_Time_Discontinuous,
         "initial Linux throttle fixture was marked discontinuous");
      Check
        (Value.Profile_Availability = Condition_Available
         and then Value.Profile_Detector = Linux_Platform_Profile
         and then Value.Profile = Profile_Performance,
         "agreeing modern Linux profile handlers were not accepted");

      Continuity := (others => <>);
      Read_Linux_Fixture ("oversized", "", False, "", False, Value, Continuity);
      Check
        (Value.Throttle_Availability = Condition_Unavailable
         and then Value.Throttle_Time_Avail = Condition_Unavailable,
         "out-of-range Linux CPUs produced a partial throttle aggregate");
   end;

   declare
      Continuity : Internal_Conditions.Throttle_Continuity;
      Value      : Internal_Conditions.Snapshot;
   begin
      Read_Linux_Fixture ("conflict", "", False, "", False, Value, Continuity);
      Check
        (Value.Throttle_Availability = Condition_Unavailable,
         "malformed Linux online CPU map produced throttle data");
      Check
        (Value.Profile_Availability = Condition_Unavailable,
         "conflicting modern handlers fell through to the legacy Linux profile");

      Continuity := (others => <>);
      Read_Linux_Fixture ("unreadable", "", False, "", False, Value, Continuity);
      Check
        (Value.Profile_Availability = Condition_Unavailable,
         "unreadable modern handler fell through to the legacy Linux profile");

      Continuity := (others => <>);
      Read_Linux_Fixture ("legacy", "", False, "", False, Value, Continuity);
      Check
        (Value.Profile_Availability = Condition_Available
         and then Value.Profile_Detector = Linux_Platform_Profile
         and then Value.Profile = Profile_Balanced,
         "legacy Linux platform profile was not used when no modern handler existed");
   end;

   declare
      Continuity : Internal_Conditions.Throttle_Continuity;
      Value      : Internal_Conditions.Snapshot;
   begin
      Read_Linux_Fixture ("reset-a", "", False, "", False, Value, Continuity);
      Check
        (not Value.Throttle_Discontinuous and then not Value.Throttle_Time_Discontinuous,
         "initial Linux reset fixture was marked discontinuous");
      Read_Linux_Fixture ("reset-b", "", False, "", False, Value, Continuity);
      Check
        (Value.Throttle_Discontinuous and then Value.Throttle_Time_Discontinuous,
         "Linux counter reset was not reported as discontinuous");
      Read_Linux_Fixture ("missing", "", False, "", False, Value, Continuity);
      Check
        (Value.Throttle_Discontinuous and then Value.Throttle_Time_Discontinuous,
         "disappearing Linux throttle sources were not reported as discontinuous");
   end;

   declare
      Continuity : Internal_Conditions.Throttle_Continuity;
      Value      : Internal_Conditions.Snapshot;
   begin
      Read_Linux_Fixture
        ("legacy", "power-saver", True, "high-operating-temperature", True, Value, Continuity);
      Check
        (Value.Profile_Availability = Condition_Available
         and then Value.Profile_Detector = Linux_Power_Profiles_Daemon
         and then Value.Profile = Profile_Reduced
         and then Value.Degradation_Availability = Condition_Available
         and then Value.Degradation = High_Operating_Temperature,
         "Linux power-profiles-daemon values were not classified");
      Read_Linux_Fixture ("legacy", "performance", True, "lap-detected", True, Value, Continuity);
      Check (Value.Degradation = Lap_Detected, "Linux lap degradation was not classified");
      Read_Linux_Fixture ("legacy", "performance", True, "firmware-limit", True, Value, Continuity);
      Check (Value.Degradation = Other_Degradation, "unknown Linux degradation was not retained");
      Read_Linux_Fixture ("legacy", "performance", True, "", True, Value, Continuity);
      Check (Value.Degradation = Not_Degraded, "empty Linux degradation was not classified as clear");
   end;
   Hooks.Reset;

   --  An initial pause can be caused by a condition unrelated to the process
   --  profile. A profile change that is stable throughout recovery belongs to
   --  the post-warmup baseline and must not keep the initial pause rejected.
   Hooks.Reject_Read (1);
   Hooks.Change_Process_Profile_From_Read (2, Process_Profile_Sustained);
   declare
      Result : Measurement;
      Report : Environment_Report;
   begin
      Benchmark (Config (Pause, Fallback_Observe), Result);
      Report := Environment (Result);
      Check
        (Report.Condition_Pauses = 1
         and then not Report.Condition_Budget_Expired
         and then not Report.Condition_Fallback_Used,
         "pre-warmup process profile prevented recovery from an unrelated condition");
      Check
        (Report.Initial_Process_Profile = Process_Profile_Default
         and then Report.Final_Process_Profile = Process_Profile_Sustained
         and then Report.Process_Profile_Changes = 1,
         "stable recovery profile was not retained as the post-warmup baseline");
   end;
   Hooks.Reset;

   if Internal_Probes.Operating_System = Internal_Probes.Darwin then
      --  Intermediate sub-second windows reuse the macOS coarse profile
      --  cache, while the terminal close obtains a fresh value. This keeps
      --  pmset off the hot collection cadence without leaving the final
      --  retained window unjudged.
      Hooks.Reset;
      declare
         Result : Measurement;
      begin
         Benchmark
           ((Config (Observe)
             with delta Operating_Conditions => Policy (Observe, Window => 0.000_001)),
            Result);
         Check (Hooks.Profile_Read_Count = 4, "intermediate windows bypassed the macOS profile cache");
      end;

      --  Each collection implementation has its own terminal-window call
      --  site. Keep all of them pinned to a fresh coarse profile read.
      Hooks.Reset;
      declare
         Result : Comparison;
      begin
         Pair_Benchmark
           ((Config (Observe)
             with delta Operating_Conditions => Policy (Observe, Window => 0.000_001)),
            Result);
         Check (Hooks.Profile_Read_Count = 4, "paired terminal window did not force the fourth profile read");
      end;

      for Schedule in Shootout_Schedule_Policy loop
         Hooks.Reset;
         declare
            Result                 : Multi_Comparison;
            Expected_Profile_Reads : constant Natural := (if Schedule = Balanced_Rounds then 4 else 5);
         begin
            Multi_Benchmark
              ((Config (Observe)
                with delta
                  Shootout_Scheduling  => Schedule,
                  Operating_Conditions => Policy (Observe, Window => 0.000_001)),
               Result);
            Check
              (Hooks.Profile_Read_Count = Expected_Profile_Reads,
               "multi-way terminal windows did not force their profile reads");
         end;
      end loop;

      Hooks.Reset;
      Hooks.Reject_Profile_Read (4);
      declare
         Failed    : Boolean := False;
         Discarded : Measurement;
      begin
         begin
            Benchmark (Config (Fail), Discarded);
         exception
            when Operating_Conditions_Unacceptable =>
               Failed := True;
         end;
         Check (Failed, "terminal forced profile rejection did not fail the run");
         Check (Hooks.Profile_Read_Count = 4, "terminal profile check was not the fourth forced read");
      end;

      --  The post-calibration boundary is also forced. A profile rejection
      --  there must recover and restart calibration instead of carrying a
      --  batch size chosen under rejected conditions into sampling.
      Hooks.Reset;
      Hooks.Reject_Profile_Read (3);
      declare
         Result : Measurement;
         Report : Environment_Report;
      begin
         Benchmark (Config (Pause, Fallback_Observe), Result);
         Report := Environment (Result);
         Check
           (Report.Condition_Pauses = 1 and then Report.Recollected_Units = 0,
            "post-calibration profile recovery did not restart calibration");
         Check
           (Hooks.Profile_Read_Count >= 6, "post-calibration recovery did not obtain fresh profile values");
      end;

      --  A sustained live rejection requires several pause polls. Only entry
      --  to Pause refreshes pmset; later polls keep sampling live process
      --  state while reusing the coarse profile cache.
      Hooks.Reset;
      Hooks.Reject_From_Read (6);
      declare
         Result : Measurement;
         Report : Environment_Report;
      begin
         Benchmark
           ((Config (Pause, Fallback_Observe)
             with delta
               Operating_Conditions =>
                 Policy (Pause, Fallback_Observe, Maximum_Pause_Time => 0.005)),
            Result);
         Report := Environment (Result);
         Check
           (Report.Condition_Fallback_Used and then Hooks.Read_Count >= 7,
            "persistent live rejection did not exercise repeated pause polls");
         Check (Hooks.Profile_Read_Count = 5, "repeated pause polls bypassed the macOS coarse profile cache");
      end;
   end if;

   --  The same final transition under Pause discards and recollects the full
   --  ten-sample window. Enabling the interference observer exercises the
   --  combined decision path without relying on host load.
   declare
      Baseline_Result : Measurement;
      Baseline_Calls  : Natural;
   begin
      Hooks.Reset;
      Calls := 0;
      Benchmark (Config (Observe, Interference => True), Baseline_Result);
      Baseline_Calls := Calls;

      Hooks.Reset;
      Hooks.Reject_Read (6);
      Calls := 0;
      declare
         Result : Measurement;
         Report : Environment_Report;
      begin
         Benchmark (Config (Pause, Fallback_Observe, Interference => True), Result);
         Report := Environment (Result);
         Check (Samples (Result) = 10, "condition pause changed the retained sample count");
         Check
           (Report.Condition_Pauses = 1
            and then Report.Affected_Units = 10
            and then Report.Recollected_Units = 10,
            "condition pause did not recollect the complete combined-watch window");
         Check
           (Calls >= Baseline_Calls + 10,
            "condition pause reported recollection without rerunning the window");
         Check
           (not Report.Condition_Budget_Expired and then not Report.Condition_Fallback_Used,
            "recovered condition pause incorrectly used its fallback");
         Check (Report.Final_Profile = Profile_Performance, "recollected run retained the rejected profile");
      end;
   end;

   --  Paired comparison treats a pair as one collection unit. Both retained
   --  measurements receive the same report after the complete affected
   --  window is run again.
   declare
      Baseline_Result : Comparison;
      Baseline_Calls  : Natural;
   begin
      Hooks.Reset;
      Calls := 0;
      Pair_Benchmark (Config (Observe), Baseline_Result);
      Baseline_Calls := Calls;

      Hooks.Reset;
      Hooks.Reject_Read (6);
      Calls := 0;
      declare
         Result           : Comparison;
         Reference_Result : Measurement;
         Contender_Result : Measurement;
         Reference_Report : Environment_Report;
         Contender_Report : Environment_Report;
      begin
         Pair_Benchmark (Config (Pause, Fallback_Observe), Result);
         Reference_Result := Reference_Measurement (Result);
         Contender_Result := Contender_Measurement (Result);
         Reference_Report := Environment (Reference_Result);
         Contender_Report := Environment (Contender_Result);
         Check
           (Samples (Reference_Result) = 10
            and then Samples (Contender_Result) = 10
            and then Reference_First_Samples (Result) + Contender_First_Samples (Result) = 10,
            "paired recollection changed retained pair count or order totals");
         Check
           (Reference_Report.Condition_Pauses = 1
            and then Reference_Report.Affected_Units = 10
            and then Reference_Report.Recollected_Units = 10
            and then Contender_Report.Condition_Pauses = 1
            and then Contender_Report.Affected_Units = 10
            and then Contender_Report.Recollected_Units = 10,
            "paired recollection report was not copied to both measurements");
         Check
           (Calls >= Baseline_Calls + 20,
            "paired comparison reported recollection without rerunning every pair");
      end;
   end;

   --  Multi-way comparison shares one condition watch across cases. Exercise
   --  both scheduling branches because they maintain separate rollback code.
   for Schedule in Shootout_Schedule_Policy loop
      Check_Multi_Recollection (Schedule);
   end loop;

   --  A calibration rejection must restart calibration after recovery. Two
   --  rejected closing reads require two restarts before sampling can begin.
   Hooks.Reset;
   Hooks.Reject_Read (4);
   Hooks.Reject_Read (8);
   declare
      Result : Measurement;
      Report : Environment_Report;
   begin
      Benchmark (Config (Pause, Fallback_Observe), Result);
      Report := Environment (Result);
      Check
        (Report.Condition_Pauses = 2 and then Report.Recollected_Units = 0,
         "calibration recovery was reported as sample recollection");
      Check (Hooks.Read_Count >= 14, "calibration did not restart after each condition recovery");
   end;

   --  Linux event and duration counters are cumulative history, not a live
   --  throttle-state signal. An event increase followed by a flat duration
   --  cannot prove cooling, even after Stable_Time, so Pause must consume its
   --  budget and apply the configured fallback.
   Hooks.Reset;
   Hooks.Begin_Throttle_Event (6);
   declare
      Result : Measurement;
      Report : Environment_Report;
   begin
      Benchmark
        ((Config (Pause, Fallback_Observe)
          with delta
            Operating_Conditions =>
              Policy
                (Pause,
                 Fallback_Observe,
                 Stable_Time        => 0.001,
                 Poll_Interval      => 0.001,
                 Maximum_Pause_Time => 0.004)),
         Result);
      Report := Environment (Result);
      Check
        (Report.Condition_Pauses = 1
         and then Report.Condition_Budget_Expired
         and then Report.Condition_Fallback_Used,
         "flat cumulative throttle duration was mistaken for live cooling");
      Check
        (Report.Affected_Units = 10 and then Report.Recollected_Units = 0,
         "unresolved throttle event did not retain the fallback window");
   end;

   --  Two pauses share one cumulative budget. The test clock fixes their
   --  accounted time while real pacing leaves the wait open to external
   --  suspension. The second delayed read fits a fresh budget but exceeds the
   --  cumulative remainder, so it must use the Observe fallback while retaining
   --  its affected one-sample window.
   Hooks.Reset;
   Hooks.Reject_Read (6);
   Hooks.Reject_Read (12);
   Hooks.Delay_Read (7, 100);
   Hooks.Delay_Read (8, 100);
   Hooks.Delay_Read (13, 350);
   Hooks.Use_Test_Clock;
   declare
      Result : Measurement;
      Report : Environment_Report;
   begin
      Benchmark
        ((Config (Pause, Fallback_Observe)
          with delta
            Operating_Conditions =>
              Policy
                (Pause,
                 Fallback_Observe,
                 Window             => 0.000_001,
                 Stable_Time        => 0.002,
                 Poll_Interval      => 0.001,
                 Maximum_Pause_Time => 0.500)),
         Result);
      Report := Environment (Result);
      Check (Hooks.Test_Clock_Now = 551_000_000, "condition pauses did not consume the scripted test time");
      Check (Report.Condition_Pauses = 2, "cumulative condition budget did not reach the second pause");
      Check (Report.Condition_Budget_Expired, "second condition pause did not exhaust the cumulative budget");
      Check (Report.Condition_Fallback_Used, "expired condition budget did not use its fallback");
      Check
        (Report.Affected_Units = 2 and then Report.Recollected_Units = 1,
         "cumulative fallback did not distinguish recollected and retained windows");
   end;

   --  The same exhaustion under Fallback_Fail must not return a measurement.
   Hooks.Reset;
   Hooks.Reject_From_Read (6);
   declare
      Failed    : Boolean := False;
      Discarded : Measurement;
   begin
      begin
         Benchmark (Config (Pause, Fallback_Fail), Discarded);
      exception
         when Operating_Conditions_Unacceptable =>
            Failed := True;
      end;
      Check (Failed, "persistent condition ignored the Fail pause fallback");
   end;

   Ada.Text_IO.Put_Line ("flyology_bench condition integration smoke: PASS");
end Flyology_Bench.Internal_Condition_Integration_Smoke;
