--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Numerics.Long_Elementary_Functions;
with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Flyology_Bench.Host_Control;
with Flyology_Bench.Host_Lock;
with Flyology_Bench.Internal_Condition_Policy;
with Flyology_Bench.Internal_Condition_Test_Hooks;
with Flyology_Bench.Internal_Conditions;
with Flyology_Bench.Internal_Statistics;
with Flyology_Bench.Internal_Window_Policy;
with Flyology_Bench.Internal_Probes.Counters;

package body Flyology_Bench is
   package Math renames Ada.Numerics.Long_Elementary_Functions;
   package Counters renames Flyology_Bench.Internal_Probes.Counters;
   package Conditions renames Flyology_Bench.Internal_Conditions;
   package Condition_Policy renames Flyology_Bench.Internal_Condition_Policy;
   package Window_Policy renames Flyology_Bench.Internal_Window_Policy;
   use Flyology_Bench.Internal_Probes;

   use type Interfaces.Unsigned_64;

   subtype Float_Array is Internal_Statistics.Float_Array;

   function Observe
     (Require_Nonreduced_Profile : Boolean := True;
      Require_Profile_Detection  : Boolean := False;
      Maximum_Thermal_State      : Thermal_State_Threshold := Thermal_State_Fair;
      Require_Thermal_Detection  : Boolean := False;
      Window                     : Positive_Duration := 0.050) return Operating_Conditions_Policy
   is
     (Mode_Value                 => Observe,
      Require_Nonreduced_Profile => Require_Nonreduced_Profile,
      Require_Profile_Detection  => Require_Profile_Detection,
      Maximum_Thermal_State      => Maximum_Thermal_State,
      Require_Thermal_Detection  => Require_Thermal_Detection,
      Window                     => Window,
      others                     => <>);

   function Pause
     (On_Pause_Timeout           : Condition_Pause_Fallback;
      Require_Nonreduced_Profile : Boolean := True;
      Require_Profile_Detection  : Boolean := False;
      Maximum_Thermal_State      : Thermal_State_Threshold := Thermal_State_Fair;
      Require_Thermal_Detection  : Boolean := False;
      Window                     : Positive_Duration := 0.050;
      Stable_Time                : Positive_Duration := 0.500;
      Poll_Interval              : Positive_Duration := 0.100;
      Maximum_Pause_Time         : Positive_Duration := 30.0;
      Rewarm_Time                : Nonnegative_Duration := 0.050) return Operating_Conditions_Policy
   is
     (Mode_Value                 => Pause,
      Require_Nonreduced_Profile => Require_Nonreduced_Profile,
      Require_Profile_Detection  => Require_Profile_Detection,
      Maximum_Thermal_State      => Maximum_Thermal_State,
      Require_Thermal_Detection  => Require_Thermal_Detection,
      Window                     => Window,
      Stable_Time                => Stable_Time,
      Poll_Interval              => Poll_Interval,
      Maximum_Pause_Time         => Maximum_Pause_Time,
      Rewarm_Time                => Rewarm_Time,
      On_Pause_Timeout           => On_Pause_Timeout);

   function Fail
     (Require_Nonreduced_Profile : Boolean := True;
      Require_Profile_Detection  : Boolean := False;
      Maximum_Thermal_State      : Thermal_State_Threshold := Thermal_State_Fair;
      Require_Thermal_Detection  : Boolean := False;
      Window                     : Positive_Duration := 0.050) return Operating_Conditions_Policy
   is
     (Mode_Value                 => Fail,
      Require_Nonreduced_Profile => Require_Nonreduced_Profile,
      Require_Profile_Detection  => Require_Profile_Detection,
      Maximum_Thermal_State      => Maximum_Thermal_State,
      Require_Thermal_Detection  => Require_Thermal_Detection,
      Window                     => Window,
      others                     => <>);

   function Mode (Policy : Operating_Conditions_Policy) return Operating_Conditions_Mode
   is (Policy.Mode_Value);

   procedure Sort (Values : in out Float_Array) renames Internal_Statistics.Sort;

   function Percentile (Ordered : Float_Array; Fraction : Long_Float) return Long_Float
   renames Internal_Statistics.Percentile;

   function Lower_Tail (Confidence : Confidence_Percentage) return Long_Float
   renames Internal_Statistics.Lower_Tail;

   procedure Free_Metric_Store is new Ada.Unchecked_Deallocation (Metric_Store, Metric_Store_Access);
   procedure Free_Custom_Store is new Ada.Unchecked_Deallocation (Custom_Store, Custom_Store_Access);

   overriding
   procedure Adjust (Object : in out Metric_Store_Handle) is
   begin
      if Object.Data /= null then
         Object.Data.References := Object.Data.References + 1;
      end if;
   end Adjust;

   overriding
   procedure Finalize (Object : in out Metric_Store_Handle) is
   begin
      if Object.Data = null then
         return;
      elsif Object.Data.References = 1 then
         Free_Metric_Store (Object.Data);
      else
         Object.Data.References := Object.Data.References - 1;
         Object.Data := null;
      end if;
   end Finalize;

   overriding
   procedure Adjust (Object : in out Custom_Store_Handle) is
   begin
      if Object.Data /= null then
         Object.Data.References := Object.Data.References + 1;
      end if;
   end Adjust;

   overriding
   procedure Finalize (Object : in out Custom_Store_Handle) is
   begin
      if Object.Data = null then
         return;
      elsif Object.Data.References = 1 then
         Free_Custom_Store (Object.Data);
      else
         Object.Data.References := Object.Data.References - 1;
         Object.Data := null;
      end if;
   end Finalize;

   function Descriptor_Name (Item : Custom_Metric_Descriptor) return String
   is (if Item.Name_Length = 0 then "" else String (Item.Name_Data (1 .. Item.Name_Length)));

   function Descriptor_Unit (Item : Custom_Metric_Descriptor) return String
   is (if Item.Unit_Length = 0 then "" else String (Item.Unit_Data (1 .. Item.Unit_Length)));

   function Descriptor_Timing_Source (Item : Custom_Metric_Descriptor) return String
   is (if Item.Timing_Length = 0 then "" else String (Item.Timing_Data (1 .. Item.Timing_Length)));

   function Valid_Name (Value : String) return Boolean is
   begin
      if Value'Length = 0
        or else Value'Length > Max_Custom_Metric_Name_Length
        or else Value (Value'First) not in 'a' .. 'z'
      then
         return False;
      end if;
      for C of Value loop
         if C not in 'a' .. 'z'
           and then C not in '0' .. '9'
           and then C /= '.'
           and then C /= '_'
           and then C /= '-'
         then
            return False;
         end if;
      end loop;
      return True;
   end Valid_Name;

   function Valid_Label (Value : String; Maximum : Positive) return Boolean is
   begin
      if Value'Length = 0 or else Value'Length > Maximum then
         return False;
      end if;
      for C of Value loop
         if Character'Pos (C) < 32
           or else Character'Pos (C) > 126
           or else C = ','
           or else C = '"'
           or else C = '\'
         then
            return False;
         end if;
      end loop;
      return True;
   end Valid_Label;

   function Canonical_Builtin_Name (Axis : Metric_Axis) return String is
      Source : constant String := Metric_Name (Axis);
      Result : String (Source'Range);
   begin
      for Index in Source'Range loop
         Result (Index) :=
           (if Source (Index) in 'A' .. 'Z'
            then Character'Val (Character'Pos (Source (Index)) + Character'Pos ('a') - Character'Pos ('A'))
            elsif Source (Index) = ' '
            then '_'
            else Source (Index));
      end loop;
      return Result;
   end Canonical_Builtin_Name;

   procedure Register_Custom_Metric
     (Registry       : in out Custom_Metric_Registry;
      Name           : String;
      Unit           : String;
      Scope          : Metric_Scope;
      Attribution    : Metric_Attribution;
      Direction      : Metric_Direction;
      Semantics      : Custom_Sample_Semantics := Cumulative_Delta;
      Normalization  : Custom_Normalization := Per_Operation;
      Comparison     : Custom_Comparison_Semantics := Relative_Positive;
      Primary_Timing : Boolean := False;
      Timing_Source  : String := "";
      Resolution     : Long_Float := 0.0)
   is
      Item : Custom_Metric_Descriptor;
   begin
      if not Valid_Name (Name) then
         raise Constraint_Error with "invalid custom metric name";
      elsif not Valid_Label (Unit, Max_Custom_Metric_Unit_Length) then
         raise Constraint_Error with "invalid custom metric unit";
      elsif Primary_Timing and then not Valid_Label (Timing_Source, Max_Timing_Source_Name_Length) then
         raise Constraint_Error with "invalid timing source name";
      elsif not Primary_Timing and then Timing_Source'Length /= 0 then
         raise Constraint_Error with "a timing source requires Primary_Timing";
      elsif Primary_Timing and then Resolution <= 0.0 then
         raise Constraint_Error with "a primary timing axis requires positive resolution";
      elsif not Primary_Timing and then Resolution /= 0.0 then
         raise Constraint_Error with "resolution metadata requires a primary timing axis";
      elsif Resolution /= Resolution or else Resolution < 0.0 or else Resolution > Long_Float'Last then
         raise Constraint_Error with "invalid custom metric resolution";
      elsif Primary_Timing and then Semantics /= Completed_Elapsed then
         raise Constraint_Error with "a primary timing axis requires completed elapsed semantics";
      end if;
      for Axis in Metric_Axis loop
         if Name = Canonical_Builtin_Name (Axis) then
            raise Constraint_Error with "custom metric collides with built-in";
         end if;
      end loop;
      for Index in 1 .. Registry.Count loop
         if Name = Descriptor_Name (Registry.Descriptors (Index)) then
            raise Constraint_Error with "duplicate custom metric name";
         elsif Primary_Timing and then Registry.Descriptors (Index).Primary_Timing_Value then
            raise Constraint_Error with "only one primary timing axis is allowed";
         end if;
      end loop;
      if Registry.Count = Max_Custom_Metrics then
         raise Capacity_Error with "custom metric registry is full";
      end if;
      Item.Name_Length := Name'Length;
      for Offset in 0 .. Name'Length - 1 loop
         Item.Name_Data (Offset + 1) := Name (Name'First + Offset);
      end loop;
      Item.Unit_Length := Unit'Length;
      for Offset in 0 .. Unit'Length - 1 loop
         Item.Unit_Data (Offset + 1) := Unit (Unit'First + Offset);
      end loop;
      Item.Scope_Value := Scope;
      Item.Attribution_Value := Attribution;
      Item.Direction_Value := Direction;
      Item.Semantics_Value := Semantics;
      Item.Normalization_Value := Normalization;
      Item.Comparison_Value := Comparison;
      Item.Primary_Timing_Value := Primary_Timing;
      Item.Resolution_Value := Resolution;
      if Timing_Source'Length > 0 then
         Item.Timing_Length := Timing_Source'Length;
         for Offset in 0 .. Timing_Source'Length - 1 loop
            Item.Timing_Data (Offset + 1) := Timing_Source (Timing_Source'First + Offset);
         end loop;
      end if;
      Registry.Count := Registry.Count + 1;
      Registry.Descriptors (Registry.Count) := Item;
   end Register_Custom_Metric;

   procedure Set_Custom_Probe (Registry : in out Custom_Metric_Registry; Probe : Custom_Probe) is
   begin
      Registry.Provider := Probe;
   end Set_Custom_Probe;

   function Custom_Metrics (Registry : Custom_Metric_Registry) return Custom_Metric_Count
   is (Registry.Count);

   type Sample_Probe_State is record
      Resource_Before      : Resource_Values := [others => 0];
      Resource_Before_Mask : Interfaces.Unsigned_64 := 0;
      Scheduler_Before     : Flyology_Scheduler_Snapshot;
      Custom_Before        : Custom_Snapshot := [others => (others => <>)];
   end record;

   function Has_Any (Set : Metric_Set) return Boolean is
   begin
      for Axis in Metric_Axis loop
         if Set (Axis) then
            return True;
         end if;
      end loop;
      return False;
   end Has_Any;

   function Requested_Metric_Count (Config : Configuration) return Natural is
      Result : Natural := 0;
   begin
      for Axis in Metric_Axis loop
         if Config.Metrics (Axis) then
            Result := Result + 1;
         end if;
      end loop;
      return Result;
   end Requested_Metric_Count;

   procedure Validate_Bootstrap_Work (Config : Configuration; Interval_Count : Natural; Context : String) is
      Work : Internal_Statistics.Bootstrap_Work_Count := 0;
   begin
      Internal_Statistics.Add_Bootstrap_Work
        (Total     => Work,
         Samples   => Natural (Config.Samples),
         Resamples => Config.Bootstrap_Resamples,
         Intervals =>
           Interval_Count * (1 + Requested_Metric_Count (Config) + Natural (Config.Custom_Metrics.Count)),
         Context   => Context);
   end Validate_Bootstrap_Work;

   function Resource_Metrics_Requested (Config : Configuration) return Boolean is
   begin
      for Axis in Process_CPU_Time .. Filesystem_Output_Operations loop
         if Config.Metrics (Axis) then
            return True;
         end if;
      end loop;
      return Config.Collect_Process_Telemetry;
   end Resource_Metrics_Requested;

   function Scheduler_Metrics_Requested (Config : Configuration) return Boolean is
   begin
      for Axis in Flyology_Dispatches .. Flyology_Migrations loop
         if Config.Metrics (Axis) then
            return True;
         end if;
      end loop;
      return False;
   end Scheduler_Metrics_Requested;

   function Perf_Status (Perf : Counters.Handle; Index : Counters.Counter_Index) return Metric_Availability
   is (Counters.Status (Perf.Counters, Index));

   procedure Initialize_Metrics (Config : Configuration; Result : in out Measurement) is
   begin
      if Has_Any (Config.Metrics) or else Config.Custom_Metrics.Count > 0 then
         Result.Metric_Data.Data :=
           new Metric_Store'
             (References => 1,
              Requested  => Config.Metrics,
              Available  => Config.Metrics,
              Status     => [others => Metric_Not_Requested],
              Values     => [others => [others => 0.0]],
              Summaries  => [others => (others => <>)]);
         for Axis in Metric_Axis loop
            if Config.Metrics (Axis) then
               Result.Metric_Data.Data.Status (Axis) := Metric_Collected;
            end if;
         end loop;
         if Scheduler_Metrics_Requested (Config) and then Config.Scheduler_Probe = null then
            for Axis in Flyology_Dispatches .. Flyology_Migrations loop
               Result.Metric_Data.Data.Available (Axis) := False;
               Result.Metric_Data.Data.Status (Axis) := Probe_Failed;
            end loop;
         end if;
      end if;
      if Config.Custom_Metrics.Count > 0 then
         Result.Custom_Data.Data :=
           new Custom_Store'
             (References  => 1,
              Count       => Config.Custom_Metrics.Count,
              Descriptors => Config.Custom_Metrics.Descriptors,
              Status      => [others => [others => Metric_Not_Requested]],
              Values      => [others => [others => 0.0]],
              Summaries   => [others => (others => <>)]);
      end if;
   end Initialize_Metrics;

   procedure Initialize_Perf (Config : Configuration; Perf : in out Counters.Handle) is
      Requested : Interfaces.Unsigned_64 := 0;
   begin
      for Axis in CPU_Cycles .. Branch_Misses loop
         if Config.Metrics (Axis) and then Axis /= Instructions_Per_Cycle then
            declare
               Index : constant Natural :=
                 (case Axis is
                    when CPU_Cycles    => 0,
                    when Instructions  => 1,
                    when Cache_Misses  => 2,
                    when Branches      => 3,
                    when Branch_Misses => 4,
                    when others        => 0);
            begin
               Requested := Requested or Interfaces.Shift_Left (Interfaces.Unsigned_64'(1), Index);
            end;
         end if;
      end loop;
      if Config.Metrics (Instructions_Per_Cycle) then
         Requested := Requested or 3;
      end if;
      if Requested /= 0 then
         Counters.Open (Perf.Counters, Requested);
         Perf.Initialized := True;
      end if;
   end Initialize_Perf;

   procedure Start_Sample
     (Config : Configuration; Perf : in out Counters.Handle; State : out Sample_Probe_State)
   is
      Ignored : Boolean;
   begin
      State := (others => <>);
      if Resource_Metrics_Requested (Config) then
         Read_Resource_Snapshot (State.Resource_Before, State.Resource_Before_Mask, Ignored);
      end if;
      if Scheduler_Metrics_Requested (Config) and then Config.Scheduler_Probe /= null then
         Config.Scheduler_Probe.all (State.Scheduler_Before);
      end if;
      if Perf.Initialized then
         Counters.Start (Perf.Counters);
      end if;
      if Config.Custom_Metrics.Count > 0 then
         State.Custom_Before := [others => (Status => Probe_Failed, others => <>)];
         if Config.Custom_Metrics.Provider /= null then
            begin
               Config.Custom_Metrics.Provider.all (State.Custom_Before);
            exception
               when others =>
                  State.Custom_Before := [others => (Status => Probe_Failed, others => <>)];
            end;
         end if;
      end if;
   end Start_Sample;

   function Elapsed_Nanoseconds
     (Started : Interfaces.Unsigned_64; Finished : Interfaces.Unsigned_64) return Long_Float is
   begin
      if Finished < Started then
         raise Program_Error with "platform monotonic clock moved backwards";
      end if;
      return Long_Float (Finished - Started);
   end Elapsed_Nanoseconds;

   function Duration_Nanoseconds (Value : Duration) return Interfaces.Unsigned_64 is
      Rounded : constant Long_Float := Long_Float'Rounding (Long_Float (Value) * 1_000_000_000.0);
   begin
      if Value > 0.0 and then Rounded < 1.0 then
         return 1;
      end if;
      return Interfaces.Unsigned_64 (Rounded);
   end Duration_Nanoseconds;

   procedure Notify
     (Config : Configuration; Phase : Progress_Phase; Completed : Natural := 0; Total : Natural := 0) is
   begin
      if Config.Progress /= null then
         Config.Progress.all
           (Ada.Strings.Unbounded.To_String (Config.Progress_Name), Phase, Completed, Total);
      end if;
   end Notify;

   function Sampling_Limit_Reached
     (Config    : Configuration;
      Started   : Interfaces.Unsigned_64;
      Completed : Natural;
      Excluded  : Interfaces.Unsigned_64 := 0) return Boolean
   is
      Elapsed : constant Interfaces.Unsigned_64 := Clock_Now - Started;
   begin
      --  Time spent suspended waiting for the host is not collection time,
      --  so it must not silently truncate the sample count.
      return
        Config.Maximum_Sampling_Time > 0.0
        and then Completed >= Natural (Sample_Count'First)
        and then Elapsed >= Excluded
        and then Elapsed - Excluded >= Duration_Nanoseconds (Config.Maximum_Sampling_Time);
   end Sampling_Limit_Reached;

   procedure Record_Process_Telemetry
     (Result          : in out Measurement;
      Index           : Sample_Index;
      Elapsed         : Long_Float;
      CPU_Before      : Interfaces.Unsigned_64;
      CPU_After       : Interfaces.Unsigned_64;
      RSS_Before      : Interfaces.Unsigned_64;
      RSS_After       : Interfaces.Unsigned_64;
      Usage_Available : Boolean) is
   begin
      if not Usage_Available or else CPU_After < CPU_Before or else Elapsed <= 0.0 then
         return;
      end if;
      Result.Telemetry_Available := True;
      Result.Telemetry_CPU (Index) := 100.0 * Long_Float (CPU_After - CPU_Before) / Elapsed;
      Result.Telemetry_RSS (Index) := Long_Float (RSS_After);
      Result.Telemetry_RSS_Delta (Index) := Long_Float (RSS_After) - Long_Float (RSS_Before);
      Result.Telemetry_CPU_Total := Result.Telemetry_CPU_Total + Long_Float (CPU_After - CPU_Before);
      Result.Telemetry_Wall_Total := Result.Telemetry_Wall_Total + Elapsed;
      if Result.Telemetry_RSS_Start = 0.0 then
         Result.Telemetry_RSS_Start := Long_Float (RSS_Before);
      end if;
      Result.Telemetry_RSS_Final := Long_Float (RSS_After);
      Result.Telemetry_RSS_Peak := Long_Float'Max (Result.Telemetry_RSS_Peak, Long_Float (RSS_After));
      Result.Telemetry_RSS_Change_Total :=
        Result.Telemetry_RSS_Change_Total + Long_Float (RSS_After) - Long_Float (RSS_Before);
      Result.Telemetry_RSS_Change_Peak :=
        Long_Float'Max (Result.Telemetry_RSS_Change_Peak, Long_Float (RSS_After) - Long_Float (RSS_Before));
   end Record_Process_Telemetry;

   procedure Finish_Sample
     (Config      : Configuration;
      Perf        : in out Counters.Handle;
      State       : Sample_Probe_State;
      Result      : in out Measurement;
      Index       : Sample_Index;
      Iterations  : Iteration_Count;
      Raw_Elapsed : Long_Float)
   is
      Resource_After      : Resource_Values := [others => 0];
      Resource_After_Mask : Interfaces.Unsigned_64 := 0;
      Resource_OK         : Boolean := False;
      Perf_Sample         : Perf_Values := [others => 0];
      Perf_Mask           : Interfaces.Unsigned_64 := 0;
      Scheduler_After     : Flyology_Scheduler_Snapshot;
      Custom_After        : Custom_Snapshot := [others => (Status => Probe_Failed, others => <>)];
      Per_Operation       : constant Long_Float := Long_Float (Iterations);
      Reported_Elapsed    : Long_Float := Raw_Elapsed;

      procedure Unavailable (Axis : Metric_Axis; Reason : Metric_Availability := Probe_Failed) is
      begin
         if Result.Metric_Data.Data /= null then
            if Result.Metric_Data.Data.Available (Axis) then
               Result.Metric_Data.Data.Status (Axis) := Reason;
            end if;
            Result.Metric_Data.Data.Available (Axis) := False;
         end if;
      end Unavailable;

      procedure Store (Axis : Metric_Axis; Value : Long_Float) is
      begin
         if Result.Metric_Data.Data /= null
           and then Result.Metric_Data.Data.Requested (Axis)
           and then Result.Metric_Data.Data.Available (Axis)
         then
            Result.Metric_Data.Data.Values (Axis, Index) := Value;
         end if;
      end Store;

      procedure Store_Resource_Delta (Axis : Metric_Axis; Resource_Bit : Natural) is
      begin
         if Mask_Has (State.Resource_Before_Mask, Resource_Bit)
           and then Mask_Has (Resource_After_Mask, Resource_Bit)
           and then Resource_After (Resource_Bit) >= State.Resource_Before (Resource_Bit)
         then
            Store
              (Axis,
               Long_Float (Resource_After (Resource_Bit) - State.Resource_Before (Resource_Bit))
               / Per_Operation);
         else
            Unavailable (Axis);
         end if;
      end Store_Resource_Delta;

      function Scheduler_Delta
        (Before : Interfaces.Unsigned_64; After : Interfaces.Unsigned_64) return Long_Float is
      begin
         if After < Before then
            raise Constraint_Error with "Flyology scheduler probe counters must be monotonic";
         end if;
         return Long_Float (After - Before) / Per_Operation;
      end Scheduler_Delta;
   begin
      --  Probe ordering is fixed: built-in begin snapshots, custom begin,
      --  wall start, batch, wall finish, custom end, built-in end snapshots.
      --  The ending custom callback is therefore outside harness wall time.
      if Config.Custom_Metrics.Count > 0 and then Config.Custom_Metrics.Provider /= null then
         begin
            Config.Custom_Metrics.Provider.all (Custom_After);
         exception
            when others =>
               Custom_After := [others => (Status => Probe_Failed, others => <>)];
         end;
      end if;
      if Perf.Initialized then
         Counters.Finish (Perf.Counters, Perf_Sample, Perf_Mask);
      end if;
      if Scheduler_Metrics_Requested (Config) and then Config.Scheduler_Probe /= null then
         Config.Scheduler_Probe.all (Scheduler_After);
      end if;
      if Resource_Metrics_Requested (Config) then
         Read_Resource_Snapshot (Resource_After, Resource_After_Mask, Resource_OK);
      end if;

      if Config.Collect_Process_Telemetry then
         Record_Process_Telemetry
           (Result,
            Index,
            Raw_Elapsed,
            State.Resource_Before (Process_CPU_Index),
            Resource_After (Process_CPU_Index),
            State.Resource_Before (Resident_Bytes_Index),
            Resource_After (Resident_Bytes_Index),
            Resource_OK
            and then Mask_Has (State.Resource_Before_Mask, Process_CPU_Index)
            and then Mask_Has (Resource_After_Mask, Process_CPU_Index)
            and then Mask_Has (State.Resource_Before_Mask, Resident_Bytes_Index)
            and then Mask_Has (Resource_After_Mask, Resident_Bytes_Index));
      end if;

      if Result.Metric_Data.Data = null then
         return;
      end if;
      if Config.Subtract_Timer_Cost and then Raw_Elapsed > Result.Timer_Cost then
         Reported_Elapsed := Raw_Elapsed - Result.Timer_Cost;
      end if;
      Store (Wall_Time, Reported_Elapsed / Per_Operation);

      if Result.Metric_Data.Data.Requested (Process_CPU_Time) then
         Store_Resource_Delta (Process_CPU_Time, Process_CPU_Index);
      end if;
      if Result.Metric_Data.Data.Requested (Thread_CPU_Time) then
         Store_Resource_Delta (Thread_CPU_Time, Thread_CPU_Index);
      end if;
      if Result.Metric_Data.Data.Requested (Process_RSS) then
         if Resource_OK and then Mask_Has (Resource_After_Mask, Resident_Bytes_Index) then
            Store (Process_RSS, Long_Float (Resource_After (Resident_Bytes_Index)));
         else
            Unavailable (Process_RSS);
         end if;
      end if;
      if Result.Metric_Data.Data.Requested (Process_RSS_Change) then
         if Resource_OK
           and then Mask_Has (State.Resource_Before_Mask, Resident_Bytes_Index)
           and then Mask_Has (Resource_After_Mask, Resident_Bytes_Index)
         then
            Store
              (Process_RSS_Change,
               (Long_Float (Resource_After (Resident_Bytes_Index))
                - Long_Float (State.Resource_Before (Resident_Bytes_Index)))
               / Per_Operation);
         else
            Unavailable (Process_RSS_Change);
         end if;
      end if;
      if Result.Metric_Data.Data.Requested (Minor_Page_Faults) then
         Store_Resource_Delta (Minor_Page_Faults, Minor_Faults_Index);
      end if;
      if Result.Metric_Data.Data.Requested (Major_Page_Faults) then
         Store_Resource_Delta (Major_Page_Faults, Major_Faults_Index);
      end if;
      if Result.Metric_Data.Data.Requested (Voluntary_Context_Switches) then
         Store_Resource_Delta (Voluntary_Context_Switches, Voluntary_Switches_Index);
      end if;
      if Result.Metric_Data.Data.Requested (Involuntary_Context_Switches) then
         Store_Resource_Delta (Involuntary_Context_Switches, Involuntary_Switches_Index);
      end if;
      if Result.Metric_Data.Data.Requested (Disk_Read_Bytes) then
         Store_Resource_Delta (Disk_Read_Bytes, Disk_Read_Bytes_Index);
      end if;
      if Result.Metric_Data.Data.Requested (Disk_Written_Bytes) then
         Store_Resource_Delta (Disk_Written_Bytes, Disk_Written_Bytes_Index);
      end if;
      if Result.Metric_Data.Data.Requested (Filesystem_Input_Operations) then
         Store_Resource_Delta (Filesystem_Input_Operations, Input_Operations_Index);
      end if;
      if Result.Metric_Data.Data.Requested (Filesystem_Output_Operations) then
         Store_Resource_Delta (Filesystem_Output_Operations, Output_Operations_Index);
      end if;

      for Axis in CPU_Cycles .. Branch_Misses loop
         if Result.Metric_Data.Data.Requested (Axis) then
            if Axis = Instructions_Per_Cycle then
               if Mask_Has (Perf_Mask, Counters.Cycles_Index)
                 and then Mask_Has (Perf_Mask, Counters.Instructions_Index)
                 and then Perf_Sample (Counters.Cycles_Index) > 0
               then
                  Store
                    (Axis,
                     Long_Float (Perf_Sample (Counters.Instructions_Index))
                     / Long_Float (Perf_Sample (Counters.Cycles_Index)));
               else
                  Unavailable
                    (Axis,
                     (if not Mask_Has (Perf_Mask, Counters.Cycles_Index)
                      then Perf_Status (Perf, Counters.Cycles_Index)
                      elsif not Mask_Has (Perf_Mask, Counters.Instructions_Index)
                      then Perf_Status (Perf, Counters.Instructions_Index)
                      else Probe_Failed));
               end if;
            else
               declare
                  Perf_Index : constant Counters.Counter_Index :=
                    (case Axis is
                       when CPU_Cycles    => Counters.Cycles_Index,
                       when Instructions  => Counters.Instructions_Index,
                       when Cache_Misses  => Counters.Cache_Misses_Index,
                       when Branches      => Counters.Branches_Index,
                       when Branch_Misses => Counters.Branch_Misses_Index,
                       when others        => Counters.Cycles_Index);
               begin
                  if Mask_Has (Perf_Mask, Perf_Index) then
                     Store (Axis, Long_Float (Perf_Sample (Perf_Index)) / Per_Operation);
                  else
                     Unavailable (Axis, Perf_Status (Perf, Perf_Index));
                  end if;
               end;
            end if;
         end if;
      end loop;

      if Scheduler_Metrics_Requested (Config) then
         if Config.Scheduler_Probe = null
           or else not State.Scheduler_Before.Available
           or else not Scheduler_After.Available
         then
            for Axis in Flyology_Dispatches .. Flyology_Migrations loop
               Unavailable (Axis);
            end loop;
         else
            Store
              (Flyology_Dispatches,
               Scheduler_Delta (State.Scheduler_Before.Dispatches, Scheduler_After.Dispatches));
            Store
              (Flyology_Poll_Batches,
               Scheduler_Delta (State.Scheduler_Before.Poll_Batches, Scheduler_After.Poll_Batches));
            Store
              (Flyology_Poll_Events,
               Scheduler_Delta (State.Scheduler_Before.Poll_Events, Scheduler_After.Poll_Events));
            Store
              (Flyology_Wakeups, Scheduler_Delta (State.Scheduler_Before.Wakeups, Scheduler_After.Wakeups));
            Store
              (Flyology_Migrations,
               Scheduler_Delta (State.Scheduler_Before.Migrations_In, Scheduler_After.Migrations_In)
               + Scheduler_Delta (State.Scheduler_Before.Migrations_Out, Scheduler_After.Migrations_Out));
         end if;
      end if;

      if Result.Custom_Data.Data /= null then
         for Axis in 1 .. Result.Custom_Data.Data.Count loop
            declare
               Descriptor : constant Custom_Metric_Descriptor := Result.Custom_Data.Data.Descriptors (Axis);
               Before     : constant Custom_Value := State.Custom_Before (Axis);
               After      : constant Custom_Value := Custom_After (Axis);
               Status     : Metric_Availability := Metric_Collected;
               Value      : Long_Float := 0.0;
               Difference : Long_Long_Integer := 0;
            begin
               if Before.Status /= Metric_Collected and then Descriptor.Semantics_Value = Cumulative_Delta
               then
                  Status := Before.Status;
               elsif After.Status /= Metric_Collected then
                  Status := After.Status;
               elsif Descriptor.Semantics_Value = Cumulative_Delta then
                  if After.Counter_Value < Before.Counter_Value then
                     Status := Counter_Reset;
                  elsif Before.Counter_Value < 0
                    and then After.Counter_Value > Long_Long_Integer'Last + Before.Counter_Value
                  then
                     Status := Conversion_Overflow;
                  else
                     Difference := After.Counter_Value - Before.Counter_Value;
                     Value := Long_Float (Difference);
                  end if;
               else
                  Value := After.Sample_Value;
                  if Value /= Value
                    or else abs Value > Long_Float'Last
                    or else (Descriptor.Semantics_Value = Completed_Elapsed and then Value < 0.0)
                  then
                     Status := Invalid_Value;
                  end if;
               end if;
               if Status = Metric_Collected
                 and then Descriptor.Normalization_Value = Flyology_Bench.Per_Operation
               then
                  Value := Value / Per_Operation;
                  if Value /= Value or else abs Value > Long_Float'Last then
                     Status := Conversion_Overflow;
                  end if;
               end if;
               Result.Custom_Data.Data.Status (Axis, Index) := Status;
               if Status = Metric_Collected then
                  Result.Custom_Data.Data.Values (Axis, Index) := Value;
               end if;
            end;
         end loop;
      end if;
   end Finish_Sample;

   procedure Read_Host_CPU
     (Busy : out Host_CPU_Counters; Total : out Host_CPU_Counters; CPU_Count : out Natural)
   is
      Available : Boolean;
   begin
      Internal_Probes.Read_Host_CPU (Busy, Total, CPU_Count, Available);
      if not Available then
         raise Program_Error with "host CPU utilization query failed";
      end if;
   end Read_Host_CPU;

   procedure Host_CPU_Utilization
     (Previous_Busy  : Host_CPU_Counters;
      Previous_Total : Host_CPU_Counters;
      Current_Busy   : Host_CPU_Counters;
      Current_Total  : Host_CPU_Counters;
      CPU_Count      : Natural;
      Average        : out Long_Float;
      Peak           : out Long_Float;
      Available      : out Boolean)
   is
      Busy_Sum  : Long_Float := 0.0;
      Total_Sum : Long_Float := 0.0;
   begin
      Average := 0.0;
      Peak := 0.0;
      Available := False;
      for CPU in 0 .. CPU_Count - 1 loop
         if Current_Busy (CPU) < Previous_Busy (CPU) or else Current_Total (CPU) < Previous_Total (CPU) then
            return;
         end if;
         declare
            Busy_Delta  : constant Interfaces.Unsigned_64 := Current_Busy (CPU) - Previous_Busy (CPU);
            Total_Delta : constant Interfaces.Unsigned_64 := Current_Total (CPU) - Previous_Total (CPU);
         begin
            if Busy_Delta > Total_Delta then
               return;
            elsif Total_Delta > 0 then
               Busy_Sum := Busy_Sum + Long_Float (Busy_Delta);
               Total_Sum := Total_Sum + Long_Float (Total_Delta);
               Peak := Long_Float'Max (Peak, 100.0 * Long_Float (Busy_Delta) / Long_Float (Total_Delta));
            end if;
         end;
      end loop;
      if Total_Sum > 0.0 then
         Average := 100.0 * Busy_Sum / Total_Sum;
         Available := True;
      end if;
   end Host_CPU_Utilization;

   Maximum_Watched_CPUs : constant := 128;
   type Watched_CPU_Array is array (1 .. Maximum_Watched_CPUs) of Natural;

   --  Rolling state for the mid-run interference watch. One window spans a
   --  whole number of collection units and is judged only after it closes,
   --  so a response never lands between the two halves of a paired sample or
   --  inside a balanced multi-way round.
   type Interference_Watch is record
      Active                       : Boolean := False;
      Watched                      : Watched_CPU_Array := (others => 0);
      Watched_Total                : Natural := 0;
      Open                         : Boolean := False;
      Busy                         : Host_CPU_Counters := (others => 0);
      Total                        : Host_CPU_Counters := (others => 0);
      CPU_Count                    : Natural := 0;
      Own_Process                  : Interfaces.Unsigned_64 := 0;
      Own_Thread                   : Interfaces.Unsigned_64 := 0;
      Own_Valid                    : Boolean := False;
      Wall                         : Interfaces.Unsigned_64 := 0;
      Retakes                      : Natural := 0;
      Paused_Total                 : Interfaces.Unsigned_64 := 0;
      Interference_Paused_Total    : Interfaces.Unsigned_64 := 0;
      Condition_Paused_Total       : Interfaces.Unsigned_64 := 0;
      Foreign_Sum                  : Long_Float := 0.0;
      Conditions_Active            : Boolean := False;
      Condition_Open               : Boolean := False;
      Condition_Start              : Conditions.Snapshot;
      Condition_Last               : Conditions.Snapshot;
      Coarse_Conditions            : Conditions.Snapshot;
      Throttle_Continuity          : Conditions.Throttle_Continuity;
      Throttle_Report_Invalid      : Boolean := False;
      Throttle_Time_Report_Invalid : Boolean := False;
      Coarse_Conditions_Valid      : Boolean := False;
      Last_Coarse_Condition_Read   : Interfaces.Unsigned_64 := 0;
      Process_Baseline             : Process_Performance_Profile := Process_Profile_Unknown;
      Throttle_Recovery_Unresolved : Boolean := False;
      Report                       : Environment_Report;
      Foreign                      : Sample_Array (Sample_Index'Range) := (others => 0.0);
   end record;

   --  What the caller must do with the window that just closed.
   --  @enum Accept_Window Keep the collected units and continue.
   --  @enum Retake_Window Discard them and collect the same units again.
   --  @enum Settle_And_Retake Wait for the host, re-warm, then collect again.
   type Window_Action is (Accept_Window, Retake_Window, Settle_And_Retake);

   type Condition_Action is (Accept_Conditions, Pause_For_Conditions, Fail_Conditions);

   Coarse_Condition_Interval_NS : constant Interfaces.Unsigned_64 := 1_000_000_000;

   --  Per-sample telemetry is written by index and survives a retake intact,
   --  but the summary fields are running sums and a running maximum. A
   --  discarded window has to give its contribution back, or the reported CPU
   --  share and elapsed time describe samples that were thrown away.
   type Telemetry_Snapshot is record
      Available        : Boolean := False;
      CPU_Total        : Long_Float := 0.0;
      Wall_Total       : Long_Float := 0.0;
      RSS_Start        : Long_Float := 0.0;
      RSS_Final        : Long_Float := 0.0;
      RSS_Peak         : Long_Float := 0.0;
      RSS_Change_Total : Long_Float := 0.0;
      RSS_Change_Peak  : Long_Float := 0.0;
   end record;

   function Save_Telemetry (Result : Measurement) return Telemetry_Snapshot
   is (Available        => Result.Telemetry_Available,
       CPU_Total        => Result.Telemetry_CPU_Total,
       Wall_Total       => Result.Telemetry_Wall_Total,
       RSS_Start        => Result.Telemetry_RSS_Start,
       RSS_Final        => Result.Telemetry_RSS_Final,
       RSS_Peak         => Result.Telemetry_RSS_Peak,
       RSS_Change_Total => Result.Telemetry_RSS_Change_Total,
       RSS_Change_Peak  => Result.Telemetry_RSS_Change_Peak);

   procedure Restore_Telemetry (Result : in out Measurement; Saved : Telemetry_Snapshot) is
   begin
      Result.Telemetry_Available := Saved.Available;
      Result.Telemetry_CPU_Total := Saved.CPU_Total;
      Result.Telemetry_Wall_Total := Saved.Wall_Total;
      Result.Telemetry_RSS_Start := Saved.RSS_Start;
      Result.Telemetry_RSS_Final := Saved.RSS_Final;
      Result.Telemetry_RSS_Peak := Saved.RSS_Peak;
      Result.Telemetry_RSS_Change_Total := Saved.RSS_Change_Total;
      Result.Telemetry_RSS_Change_Peak := Saved.RSS_Change_Peak;
   end Restore_Telemetry;

   --  Our own CPU time over the window, read once as both totals.
   --
   --  Host-wide attribution subtracts the whole process, because every thread
   --  of it contributes to the host counters. Core-scoped attribution
   --  subtracts only the placed thread, because only that thread is bound to
   --  the watched CPUs. Subtracting the whole process there would deduct time
   --  our threads spent on CPUs outside the watched set and under-report
   --  foreign load, which fails silently; subtracting only the placed thread
   --  over-reports instead, which is visible. The difference between the two
   --  is what the dilution check measures.
   procedure Read_Own_CPU
     (Process_CPU : out Interfaces.Unsigned_64; Thread_CPU : out Interfaces.Unsigned_64; Valid : out Boolean)
   is
      Values    : Resource_Values := (others => 0);
      Mask      : Interfaces.Unsigned_64 := 0;
      Available : Boolean := False;
   begin
      Read_Resource_Snapshot (Values, Mask, Available);
      Valid :=
        Available and then Mask_Has (Mask, Process_CPU_Index) and then Mask_Has (Mask, Thread_CPU_Index);
      if not Valid then
         Process_CPU := 0;
         Thread_CPU := 0;
         return;
      end if;
      Process_CPU := Values (Process_CPU_Index);
      Thread_CPU := Values (Thread_CPU_Index);
   end Read_Own_CPU;

   --  Foreign share of the watched CPUs' capacity, in percent. The host busy
   --  ratio is scaled by wall time rather than converted from ticks, so the
   --  platform tick length never enters the arithmetic.
   procedure Foreign_Utilization
     (Watch         : Interference_Watch;
      Current_Busy  : Host_CPU_Counters;
      Current_Total : Host_CPU_Counters;
      Own_Delta     : Long_Float;
      Other_Delta   : Long_Float;
      Wall_Delta    : Long_Float;
      Foreign       : out Long_Float;
      Dilution      : out Long_Float;
      Available     : out Boolean)
   is
      Busy_Sum  : Long_Float := 0.0;
      Total_Sum : Long_Float := 0.0;
      Counted   : Natural := 0;
      Capacity  : Long_Float;
      Busy_Time : Long_Float;

      procedure Accumulate (CPU : Natural) is
      begin
         if Current_Busy (CPU) < Watch.Busy (CPU) or else Current_Total (CPU) < Watch.Total (CPU) then
            return;
         end if;
         declare
            Busy_Delta  : constant Interfaces.Unsigned_64 := Current_Busy (CPU) - Watch.Busy (CPU);
            Total_Delta : constant Interfaces.Unsigned_64 := Current_Total (CPU) - Watch.Total (CPU);
         begin
            if Busy_Delta > Total_Delta or else Total_Delta = 0 then
               return;
            end if;
            Busy_Sum := Busy_Sum + Long_Float (Busy_Delta);
            Total_Sum := Total_Sum + Long_Float (Total_Delta);
            Counted := Counted + 1;
         end;
      end Accumulate;
   begin
      Foreign := 0.0;
      Dilution := 0.0;
      Available := False;
      if Watch.Report.Attribution = Core_Scoped then
         for Index in 1 .. Watch.Watched_Total loop
            if Watch.Watched (Index) < Watch.CPU_Count then
               Accumulate (Watch.Watched (Index));
            end if;
         end loop;
      else
         for CPU in 0 .. Watch.CPU_Count - 1 loop
            Accumulate (CPU);
         end loop;
      end if;
      if Counted = 0 or else Total_Sum <= 0.0 or else Wall_Delta <= 0.0 then
         return;
      end if;
      Capacity := Long_Float (Counted) * Wall_Delta;
      Busy_Time := (Busy_Sum / Total_Sum) * Capacity;
      Foreign := 100.0 * Long_Float'Max (0.0, Busy_Time - Own_Delta) / Capacity;
      --  The share of the watched capacity that this process's other threads
      --  could account for. It is an upper bound: they may have run entirely
      --  on CPUs outside the watched set.
      Dilution := 100.0 * Long_Float'Max (0.0, Other_Delta) / Capacity;
      Available := True;
   end Foreign_Utilization;

   procedure Open_Interference_Window (Watch : in out Interference_Watch) is
   begin
      if not Watch.Active then
         return;
      end if;
      Read_Host_CPU (Watch.Busy, Watch.Total, Watch.CPU_Count);
      Read_Own_CPU (Watch.Own_Process, Watch.Own_Thread, Watch.Own_Valid);
      Watch.Wall := Clock_Now;
      Watch.Open := True;
   end Open_Interference_Window;

   --  Close the open window, record what it saw, and decide what happens to
   --  the units it covered.
   procedure Judge_Window
     (Config : Configuration;
      Watch  : in out Interference_Watch;
      First  : Sample_Index;
      Last   : Sample_Index;
      Action : out Window_Action)
   is
      Current_Busy  : Host_CPU_Counters := (others => 0);
      Current_Total : Host_CPU_Counters := (others => 0);
      Current_Count : Natural := 0;
      Process_After : Interfaces.Unsigned_64;
      Thread_After  : Interfaces.Unsigned_64;
      Own_Valid     : Boolean;
      Finished      : Interfaces.Unsigned_64;
      Foreign       : Long_Float := 0.0;
      Dilution      : Long_Float := 0.0;
      Available     : Boolean := False;
      Wall_Delta    : Long_Float := 0.0;
      Units         : constant Natural := Natural (Last) - Natural (First) + 1;
   begin
      Action := Accept_Window;
      if not Watch.Active or else not Watch.Open then
         return;
      end if;
      Watch.Open := False;
      Read_Host_CPU (Current_Busy, Current_Total, Current_Count);
      Read_Own_CPU (Process_After, Thread_After, Own_Valid);
      Finished := Clock_Now;

      if Current_Count = Watch.CPU_Count
        and then Finished > Watch.Wall
        and then Own_Valid
        and then Watch.Own_Valid
        and then Process_After >= Watch.Own_Process
        and then Thread_After >= Watch.Own_Thread
      then
         Wall_Delta := Long_Float (Finished - Watch.Wall);
         declare
            Process_Delta : constant Long_Float := Long_Float (Process_After - Watch.Own_Process);
            Thread_Delta  : constant Long_Float := Long_Float (Thread_After - Watch.Own_Thread);
         begin
            Foreign_Utilization
              (Watch,
               Current_Busy,
               Current_Total,
               (if Watch.Report.Attribution = Core_Scoped then Thread_Delta else Process_Delta),
               Process_Delta - Thread_Delta,
               Wall_Delta,
               Foreign,
               Dilution,
               Available);
         end;
      end if;

      if not Available then
         return;
      end if;

      --  Placement binds only the calling thread, so another thread of this
      --  process can occupy a watched CPU, where its time is
      --  indistinguishable from foreign load. Once those threads can account
      --  for more of the watched capacity than the configured limit, the
      --  core-scoped answer cannot address the question the limit asks. The
      --  run drops to host-wide, which is well defined for a multi-threaded
      --  process, rather than reporting its own runtime as interference. The
      --  window that revealed it is not recorded, because its value was
      --  computed under the attribution being abandoned.
      if Watch.Report.Attribution = Core_Scoped
        and then Dilution > Config.Interference.Maximum_Foreign_CPU_Percent
      then
         Watch.Report.Attribution := Host_Wide;
         Watch.Report.Attribution_Diluted := True;
         Watch.Report.Watched_CPUs := 0;
         Watch.Watched_Total := 0;
         return;
      end if;

      for Index in First .. Last loop
         Watch.Foreign (Index) := Foreign;
      end loop;
      Watch.Report.Watched := True;
      Watch.Report.Windows := Watch.Report.Windows + 1;
      Watch.Report.Peak_Foreign_CPU_Percent :=
        Long_Float'Max (Watch.Report.Peak_Foreign_CPU_Percent, Foreign);
      Watch.Foreign_Sum := Watch.Foreign_Sum + Foreign;

      if Foreign <= Config.Interference.Maximum_Foreign_CPU_Percent then
         Watch.Report.Observed_Samples := Watch.Report.Observed_Samples + Units;
         return;
      end if;

      --  A window shorter than the configured minimum is recorded but never
      --  acted on: below one counter tick the estimate is mostly
      --  quantization, and discarding samples over it would be noise
      --  masquerading as hygiene.
      if Wall_Delta < Long_Float (Duration_Nanoseconds (Config.Interference.Window)) then
         Watch.Report.Contaminated_Samples := Watch.Report.Contaminated_Samples + Units;
         Watch.Report.Observed_Samples := Watch.Report.Observed_Samples + Units;
         return;
      end if;

      if Config.Interference.Response = Observe
        or else Watch.Retakes + Units > Config.Interference.Maximum_Retakes
      then
         if Config.Interference.Response /= Observe then
            Watch.Report.Budget_Exhausted := True;
         end if;
         Watch.Report.Contaminated_Samples := Watch.Report.Contaminated_Samples + Units;
         Watch.Report.Observed_Samples := Watch.Report.Observed_Samples + Units;
         return;
      end if;

      Watch.Retakes := Watch.Retakes + Units;
      Watch.Report.Retaken_Samples := Watch.Report.Retaken_Samples + Units;
      Action := (if Config.Interference.Response = Pause then Settle_And_Retake else Retake_Window);
   end Judge_Window;

   --  Suspend collection until foreign load stays within its limit for
   --  Settle_Time, bounded by whatever remains of the pause budget.
   procedure Await_Foreign_Settle (Config : Configuration; Watch : in out Interference_Watch) is
      Budget        : constant Interfaces.Unsigned_64 :=
        Duration_Nanoseconds (Config.Interference.Maximum_Pause_Time);
      Required      : constant Interfaces.Unsigned_64 :=
        Duration_Nanoseconds (Config.Interference.Settle_Time);
      Started       : constant Interfaces.Unsigned_64 := Clock_Now;
      Stable        : Interfaces.Unsigned_64 := 0;
      Foreign       : Long_Float;
      Available     : Boolean;
      Current_Busy  : Host_CPU_Counters := (others => 0);
      Current_Total : Host_CPU_Counters := (others => 0);
      Current_Count : Natural := 0;
      Process_After : Interfaces.Unsigned_64;
      Thread_After  : Interfaces.Unsigned_64;
      Own_Valid     : Boolean;
      Finished      : Interfaces.Unsigned_64;
      Completed     : Natural;
      Dilution      : Long_Float;
   begin
      if Watch.Interference_Paused_Total >= Budget then
         Watch.Report.Budget_Exhausted := True;
         return;
      end if;
      Watch.Report.Pauses := Watch.Report.Pauses + 1;
      Notify (Config, Waiting_For_CPU_Quiescence, 0, 100);
      loop
         Open_Interference_Window (Watch);
         delay Config.Interference.Window;
         Read_Host_CPU (Current_Busy, Current_Total, Current_Count);
         Read_Own_CPU (Process_After, Thread_After, Own_Valid);
         Finished := Clock_Now;
         Available := False;
         Foreign := 0.0;
         if Current_Count = Watch.CPU_Count
           and then Finished > Watch.Wall
           and then Own_Valid
           and then Watch.Own_Valid
           and then Process_After >= Watch.Own_Process
           and then Thread_After >= Watch.Own_Thread
         then
            declare
               Process_Delta : constant Long_Float := Long_Float (Process_After - Watch.Own_Process);
               Thread_Delta  : constant Long_Float := Long_Float (Thread_After - Watch.Own_Thread);
            begin
               Foreign_Utilization
                 (Watch,
                  Current_Busy,
                  Current_Total,
                  (if Watch.Report.Attribution = Core_Scoped then Thread_Delta else Process_Delta),
                  Process_Delta - Thread_Delta,
                  Long_Float (Finished - Watch.Wall),
                  Foreign,
                  Dilution,
                  Available);
            end;
         end if;
         Watch.Open := False;

         if Available and then Foreign <= Config.Interference.Maximum_Foreign_CPU_Percent then
            Stable := Stable + (Finished - Watch.Wall);
         else
            Stable := 0;
         end if;
         Completed :=
           Natural'Min
             (100,
              Natural
                (Long_Float'Floor
                   (100.0 * Long_Float (Stable) / Long_Float'Max (1.0, Long_Float (Required)))));
         Notify (Config, Waiting_For_CPU_Quiescence, Completed, 100);
         exit when Stable >= Required;
         --  Exhausting the budget degrades the run to Observe rather than
         --  discarding everything collected so far.
         if Clock_Now - Started >= Budget - Watch.Interference_Paused_Total then
            Watch.Report.Budget_Exhausted := True;
            exit;
         end if;
      end loop;
      declare
         Spent : constant Interfaces.Unsigned_64 := Clock_Now - Started;
      begin
         Watch.Paused_Total := Watch.Paused_Total + Spent;
         Watch.Interference_Paused_Total := Watch.Interference_Paused_Total + Spent;
         Watch.Report.Paused_Nanoseconds := Watch.Report.Paused_Nanoseconds + Long_Float (Spent);
      end;
   end Await_Foreign_Settle;

   procedure Read_Conditions
     (Watch         : in out Interference_Watch;
      Value         : out Conditions.Snapshot;
      Force_Profile : Boolean := False;
      Deadline      : Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last;
      Account_Time  : Boolean := True)
   is
      Started         : constant Interfaces.Unsigned_64 := Clock_Now;
      Now             : constant Interfaces.Unsigned_64 := Started;
      Include_Profile : constant Boolean :=
        Force_Profile
        or else Operating_System = Linux
        or else not Watch.Coarse_Conditions_Valid
        or else Now < Watch.Last_Coarse_Condition_Read
        or else Now - Watch.Last_Coarse_Condition_Read >= Coarse_Condition_Interval_NS;
   begin
      Conditions.Read
        (Value, Watch.Throttle_Continuity, Include_Profile => Include_Profile, Deadline => Deadline);
      if Include_Profile then
         Watch.Coarse_Conditions.Profile_Availability := Value.Profile_Availability;
         Watch.Coarse_Conditions.Profile_Detector := Value.Profile_Detector;
         Watch.Coarse_Conditions.Profile := Value.Profile;
         Watch.Coarse_Conditions.Power_Source := Value.Power_Source;
         Watch.Coarse_Conditions.Degradation_Availability := Value.Degradation_Availability;
         Watch.Coarse_Conditions.Degradation := Value.Degradation;
         Watch.Coarse_Conditions_Valid := True;
         Watch.Last_Coarse_Condition_Read := Clock_Now;
      else
         Value.Profile_Availability := Watch.Coarse_Conditions.Profile_Availability;
         Value.Profile_Detector := Watch.Coarse_Conditions.Profile_Detector;
         Value.Profile := Watch.Coarse_Conditions.Profile;
         Value.Power_Source := Watch.Coarse_Conditions.Power_Source;
         Value.Degradation_Availability := Watch.Coarse_Conditions.Degradation_Availability;
         Value.Degradation := Watch.Coarse_Conditions.Degradation;
      end if;
      if Account_Time then
         declare
            Spent : constant Interfaces.Unsigned_64 := Clock_Now - Started;
         begin
            Watch.Paused_Total :=
              (if Watch.Paused_Total > Interfaces.Unsigned_64'Last - Spent
               then Interfaces.Unsigned_64'Last
               else Watch.Paused_Total + Spent);
         end;
      end if;
   end Read_Conditions;

   function Conditions_Unacceptable
     (Config                      : Configuration;
      Watch                       : Interference_Watch;
      Current                     : Conditions.Snapshot;
      Throttle_Delta              : Interfaces.Unsigned_64 := 0;
      Throttle_Time_Delta         : Interfaces.Unsigned_64 := 0;
      Throttle_Discontinuous      : Boolean := False;
      Throttle_Time_Discontinuous : Boolean := False) return Boolean
   is
      Policy : Operating_Conditions_Policy renames Config.Operating_Conditions;
   begin
      if Mode (Policy) = Disabled then
         return False;
      end if;
      declare
         Required        : constant Condition_Policy.Requirements :=
           (Require_Nonreduced_Profile => Policy.Require_Nonreduced_Profile,
            Require_Profile_Detection  => Policy.Require_Profile_Detection,
            Maximum_Thermal_State      => Policy.Maximum_Thermal_State,
            Require_Thermal_Detection  => Policy.Require_Thermal_Detection);
         State           : constant Condition_Policy.State :=
           (Profile_Availability     => Current.Profile_Availability,
            Profile                  => Current.Profile,
            Low_Power_Availability   => Current.Low_Power_Availability,
            Low_Power_Mode           => Current.Low_Power_Mode,
            Process_Profile_Avail    => Current.Process_Profile_Avail,
            Process_Profile          => Current.Process_Profile,
            Thermal_Availability     => Current.Thermal_Availability,
            Thermal_State            => Current.Thermal_State,
            Degradation_Availability => Current.Degradation_Availability,
            Degradation              => Current.Degradation,
            Throttle_Availability    => Current.Throttle_Availability,
            Throttle_Time_Avail      => Current.Throttle_Time_Avail);
         Throttle_Events : constant Condition_Policy.Counter_Evidence :=
           (Availability  => Current.Throttle_Availability,
            Increased     => Throttle_Delta > 0,
            Increase      => Throttle_Delta,
            Discontinuous => Throttle_Discontinuous);
         Throttle_Time   : constant Condition_Policy.Counter_Evidence :=
           (Availability  => Current.Throttle_Time_Avail,
            Increased     => Throttle_Time_Delta > 0,
            Increase      => Throttle_Time_Delta,
            Discontinuous => Throttle_Time_Discontinuous);
      begin
         return
           Watch.Throttle_Recovery_Unresolved
           or else Condition_Policy.Unacceptable
                     (Required, State, Watch.Process_Baseline, Throttle_Events, Throttle_Time);
      end;
   end Conditions_Unacceptable;

   function Condition_Mode_Action
     (Policy_Mode : Operating_Conditions_Mode; Rejected : Boolean) return Condition_Action is
   begin
      case Condition_Policy.Action_For (Policy_Mode, Rejected) is
         when Condition_Policy.Policy_Accept =>
            return Accept_Conditions;

         when Condition_Policy.Policy_Pause  =>
            return Pause_For_Conditions;

         when Condition_Policy.Policy_Fail   =>
            return Fail_Conditions;
      end case;
   end Condition_Mode_Action;

   procedure Add_Throttle_Events (Watch : in out Interference_Watch; Increase : Interfaces.Unsigned_64) is
   begin
      if Watch.Throttle_Report_Invalid then
         return;
      end if;
      if Watch.Report.Throttle_Events > Interfaces.Unsigned_64'Last - Increase then
         Watch.Throttle_Report_Invalid := True;
         Watch.Report.Throttle_Availability := Condition_Unavailable;
      else
         Watch.Report.Throttle_Events := Watch.Report.Throttle_Events + Increase;
      end if;
   end Add_Throttle_Events;

   procedure Add_Throttle_Time (Watch : in out Interference_Watch; Increase : Interfaces.Unsigned_64) is
   begin
      if Watch.Throttle_Time_Report_Invalid then
         return;
      end if;
      if Watch.Report.Throttle_Milliseconds > Interfaces.Unsigned_64'Last - Increase then
         Watch.Throttle_Time_Report_Invalid := True;
         Watch.Report.Throttle_Time_Avail := Condition_Unavailable;
      else
         Watch.Report.Throttle_Milliseconds := Watch.Report.Throttle_Milliseconds + Increase;
      end if;
   end Add_Throttle_Time;

   procedure Record_Condition_Snapshot
     (Watch   : in out Interference_Watch;
      Current : Conditions.Snapshot;
      Initial : Boolean := False;
      Final   : Boolean := False)
   is
      Report : Environment_Report renames Watch.Report;
   begin
      if Current.Profile_Availability = Condition_Available then
         if Report.Profile_Availability = Condition_Available
           and then Watch.Condition_Last.Profile_Availability = Condition_Available
           and then Current.Profile /= Watch.Condition_Last.Profile
         then
            Report.Profile_Changes := Report.Profile_Changes + 1;
         end if;
         Report.Profile_Availability := Condition_Available;
         Report.Profile_Detector := Current.Profile_Detector;
         Report.Final_Profile := Current.Profile;
         if Initial then
            Report.Initial_Profile := Current.Profile;
         end if;
      else
         if Initial then
            Report.Profile_Availability := Condition_Unavailable;
         end if;
         if Final then
            Report.Final_Profile := Profile_Unknown;
         end if;
      end if;

      if Current.Power_Source /= Power_Source_Unknown then
         Report.Final_Power_Source := Current.Power_Source;
         if Initial then
            Report.Initial_Power_Source := Current.Power_Source;
         end if;
      elsif Final then
         Report.Final_Power_Source := Power_Source_Unknown;
      end if;

      if Current.Low_Power_Availability = Condition_Available then
         Report.Low_Power_Availability := Condition_Available;
         Report.Low_Power_Detector := Current.Low_Power_Detector;
         Report.Final_Low_Power_Mode := Current.Low_Power_Mode;
         if Initial then
            Report.Initial_Low_Power_Mode := Current.Low_Power_Mode;
         end if;
         Report.Worst_Low_Power_Mode :=
           Condition_Policy.Merge_Low_Power_Worst (Report.Worst_Low_Power_Mode, Current.Low_Power_Mode);
      else
         if Initial then
            Report.Low_Power_Availability := Condition_Unavailable;
         end if;
         if Final then
            Report.Final_Low_Power_Mode := Low_Power_Mode_Unknown;
         end if;
      end if;

      if Current.Process_Profile_Avail = Condition_Available then
         if Report.Process_Profile_Avail = Condition_Available
           and then Watch.Condition_Last.Process_Profile_Avail = Condition_Available
           and then Current.Process_Profile /= Watch.Condition_Last.Process_Profile
         then
            Report.Process_Profile_Changes := Report.Process_Profile_Changes + 1;
         end if;
         Report.Process_Profile_Avail := Condition_Available;
         Report.Process_Profile_Detector := Current.Process_Profile_Detector;
         Report.Final_Process_Profile := Current.Process_Profile;
         if Initial then
            Report.Initial_Process_Profile := Current.Process_Profile;
         end if;
      else
         if Initial then
            Report.Process_Profile_Avail := Condition_Unavailable;
         end if;
         if Final then
            Report.Final_Process_Profile := Process_Profile_Unknown;
         end if;
      end if;

      if Current.Thermal_Availability = Condition_Available then
         Report.Thermal_Availability := Condition_Available;
         Report.Thermal_Detector := Current.Thermal_Detector;
         Report.Final_Thermal_State := Current.Thermal_State;
         if Initial or else Report.Worst_Thermal_State = Thermal_State_Unknown then
            Report.Worst_Thermal_State := Current.Thermal_State;
         else
            Report.Worst_Thermal_State :=
              Host_Thermal_State'Max (Report.Worst_Thermal_State, Current.Thermal_State);
         end if;
         if Initial then
            Report.Initial_Thermal_State := Current.Thermal_State;
         end if;
      else
         if Initial then
            Report.Thermal_Availability := Condition_Unavailable;
         end if;
         if Final then
            Report.Final_Thermal_State := Thermal_State_Unknown;
         end if;
      end if;

      if Current.Degradation_Availability = Condition_Available then
         Report.Degradation_Availability := Condition_Available;
         Report.Final_Degradation := Current.Degradation;
         if Initial then
            Report.Initial_Degradation := Current.Degradation;
         end if;
         Report.Worst_Degradation :=
           Condition_Policy.Merge_Degradation_Worst (Report.Worst_Degradation, Current.Degradation);
      else
         if Initial then
            Report.Degradation_Availability := Condition_Unavailable;
         end if;
         if Final then
            Report.Final_Degradation := Degradation_Unknown;
         end if;
      end if;

      Watch.Throttle_Report_Invalid := Watch.Throttle_Report_Invalid or else Current.Throttle_Discontinuous;
      Watch.Throttle_Time_Report_Invalid :=
        Watch.Throttle_Time_Report_Invalid or else Current.Throttle_Time_Discontinuous;
      if Current.Throttle_Detector = Linux_CPU_Thermal_Throttle then
         Report.Throttle_Detector := Current.Throttle_Detector;
      end if;
      if Watch.Throttle_Report_Invalid then
         Report.Throttle_Availability := Condition_Unavailable;
      elsif Current.Throttle_Availability = Condition_Available then
         Report.Throttle_Availability := Condition_Available;
      elsif Initial then
         Report.Throttle_Availability := Condition_Unavailable;
      end if;
      if Watch.Throttle_Time_Report_Invalid then
         Report.Throttle_Time_Avail := Condition_Unavailable;
      elsif Current.Throttle_Time_Avail = Condition_Available then
         Report.Throttle_Time_Avail := Condition_Available;
      elsif Initial then
         Report.Throttle_Time_Avail := Condition_Unavailable;
      end if;
      Watch.Condition_Last := Current;
   end Record_Condition_Snapshot;

   --  Test timing is limited to condition waits so collection and every
   --  production selection continue to use the platform monotonic clock.
   function Condition_Clock_Now return Interfaces.Unsigned_64 is
   begin
      if Internal_Condition_Test_Hooks.Enabled then
         if Internal_Condition_Test_Hooks.Test_Clock_Active then
            return Internal_Condition_Test_Hooks.Test_Clock_Now;
         end if;
      end if;
      return Clock_Now;
   end Condition_Clock_Now;

   --  Retain real pacing when the test clock advances, allowing an external
   --  suspension to exercise the same wait without changing accounted time.
   procedure Delay_For_Conditions (Nanoseconds : Interfaces.Unsigned_64) is
   begin
      if Internal_Condition_Test_Hooks.Enabled then
         if Internal_Condition_Test_Hooks.Test_Clock_Active then
            Internal_Condition_Test_Hooks.Advance_Test_Clock (Nanoseconds);
         end if;
      end if;
      delay Duration (Long_Float (Nanoseconds) / 1_000_000_000.0);
   end Delay_For_Conditions;

   procedure Await_Condition_Settle
     (Config : Configuration; Watch : in out Interference_Watch; Recovered : out Boolean)
   is
      Policy                      : Operating_Conditions_Policy renames Config.Operating_Conditions;
      Budget                      : constant Interfaces.Unsigned_64 :=
        Duration_Nanoseconds (Policy.Maximum_Pause_Time);
      Required                    : constant Interfaces.Unsigned_64 :=
        Duration_Nanoseconds (Policy.Stable_Time);
      Poll_NS                     : constant Interfaces.Unsigned_64 :=
        Duration_Nanoseconds (Policy.Poll_Interval);
      Started                     : Interfaces.Unsigned_64;
      Deadline                    : Interfaces.Unsigned_64;
      Remaining_Budget            : Interfaces.Unsigned_64;
      Previous_Time               : Interfaces.Unsigned_64;
      Previous_Acceptable         : Boolean;
      Current_Acceptable          : Boolean;
      Stable                      : Interfaces.Unsigned_64 := 0;
      Previous                    : Conditions.Snapshot;
      Current                     : Conditions.Snapshot;
      Throttle_Increase           : Interfaces.Unsigned_64;
      Throttle_Time_Increase      : Interfaces.Unsigned_64;
      Throttle_Discontinuous      : Boolean;
      Throttle_Time_Discontinuous : Boolean;
      Now                         : Interfaces.Unsigned_64;
      Completed                   : Natural;
   begin
      Recovered := False;
      if Watch.Condition_Paused_Total >= Budget then
         Watch.Report.Condition_Budget_Expired := True;
         Watch.Report.Condition_Fallback_Used := True;
         Watch.Throttle_Recovery_Unresolved := False;
         case Condition_Policy.Timeout_Action (Policy.On_Pause_Timeout) is
            when Condition_Policy.Policy_Accept =>
               null;

            when Condition_Policy.Policy_Fail   =>
               raise Operating_Conditions_Unacceptable with "operating-condition pause budget exhausted";

            when Condition_Policy.Policy_Pause  =>
               raise Program_Error with "invalid operating-condition timeout action";
         end case;
         return;
      end if;
      Remaining_Budget := Budget - Watch.Condition_Paused_Total;
      Watch.Report.Condition_Pauses := Watch.Report.Condition_Pauses + 1;
      Started := Condition_Clock_Now;
      Deadline :=
        (if Started > Interfaces.Unsigned_64'Last - Remaining_Budget
         then Interfaces.Unsigned_64'Last
         else Started + Remaining_Budget);
      Read_Conditions (Watch, Previous, Force_Profile => True, Deadline => Deadline, Account_Time => False);
      declare
         Event_Evidence : constant Condition_Policy.Counter_Evidence :=
           Condition_Policy.Compare_Counter
             ((Availability => Watch.Condition_Last.Throttle_Availability,
               Value        => Watch.Condition_Last.Throttle_Total),
              (Availability => Previous.Throttle_Availability, Value => Previous.Throttle_Total));
         Time_Evidence  : constant Condition_Policy.Counter_Evidence :=
           Condition_Policy.Compare_Counter
             ((Availability => Watch.Condition_Last.Throttle_Time_Avail,
               Value        => Watch.Condition_Last.Throttle_Time_Total_MS),
              (Availability => Previous.Throttle_Time_Avail, Value => Previous.Throttle_Time_Total_MS));
      begin
         Throttle_Increase := Event_Evidence.Increase;
         Throttle_Time_Increase := Time_Evidence.Increase;
         Throttle_Discontinuous := Event_Evidence.Discontinuous or else Previous.Throttle_Discontinuous;
         Throttle_Time_Discontinuous :=
           Time_Evidence.Discontinuous or else Previous.Throttle_Time_Discontinuous;
         Watch.Throttle_Report_Invalid := Watch.Throttle_Report_Invalid or else Throttle_Discontinuous;
         Watch.Throttle_Time_Report_Invalid :=
           Watch.Throttle_Time_Report_Invalid or else Throttle_Time_Discontinuous;
         if Event_Evidence.Availability = Condition_Available and then not Throttle_Discontinuous then
            Add_Throttle_Events (Watch, Throttle_Increase);
         end if;
         if Time_Evidence.Availability = Condition_Available and then not Throttle_Time_Discontinuous then
            Add_Throttle_Time (Watch, Throttle_Time_Increase);
         end if;
         --  Linux cumulative duration changes only after a throttle episode
         --  ends; a flat value cannot establish that an in-progress episode
         --  cooled. Without a separate live status, an observed event keeps
         --  recovery unresolved until the cumulative pause fallback applies.
         Watch.Throttle_Recovery_Unresolved :=
           Watch.Throttle_Recovery_Unresolved or else Throttle_Increase > 0;
      end;
      Record_Condition_Snapshot (Watch, Previous);
      Previous_Time := Condition_Clock_Now;
      Previous_Acceptable :=
        not Conditions_Unacceptable
              (Config,
               Watch,
               Previous,
               Throttle_Increase,
               Throttle_Time_Increase,
               Throttle_Discontinuous,
               Throttle_Time_Discontinuous);
      Notify (Config, Waiting_For_Operating_Conditions, 0, 100);
      loop
         declare
            Elapsed  : constant Interfaces.Unsigned_64 := Condition_Clock_Now - Started;
            Sleep_NS : Interfaces.Unsigned_64;
         begin
            exit when Elapsed >= Remaining_Budget;
            Sleep_NS := Interfaces.Unsigned_64'Min (Poll_NS, Remaining_Budget - Elapsed);
            Delay_For_Conditions (Sleep_NS);
         end;
         --  The first pause read above force-refreshes coarse profile state.
         --  Keep live thermal state on every poll, but let macOS pmset values
         --  use their one-second cache so the observer does not launch three
         --  helper processes at every poll interval.
         Read_Conditions (Watch, Current, Deadline => Deadline, Account_Time => False);
         Now := Condition_Clock_Now;
         declare
            Event_Evidence : constant Condition_Policy.Counter_Evidence :=
              Condition_Policy.Compare_Counter
                ((Availability => Previous.Throttle_Availability, Value => Previous.Throttle_Total),
                 (Availability => Current.Throttle_Availability, Value => Current.Throttle_Total));
            Time_Evidence  : constant Condition_Policy.Counter_Evidence :=
              Condition_Policy.Compare_Counter
                ((Availability => Previous.Throttle_Time_Avail, Value => Previous.Throttle_Time_Total_MS),
                 (Availability => Current.Throttle_Time_Avail, Value => Current.Throttle_Time_Total_MS));
         begin
            Throttle_Increase := Event_Evidence.Increase;
            Throttle_Time_Increase := Time_Evidence.Increase;
            Throttle_Discontinuous := Event_Evidence.Discontinuous or else Current.Throttle_Discontinuous;
            Throttle_Time_Discontinuous :=
              Time_Evidence.Discontinuous or else Current.Throttle_Time_Discontinuous;
            Watch.Throttle_Report_Invalid := Watch.Throttle_Report_Invalid or else Throttle_Discontinuous;
            Watch.Throttle_Time_Report_Invalid :=
              Watch.Throttle_Time_Report_Invalid or else Throttle_Time_Discontinuous;
            if Event_Evidence.Availability = Condition_Available and then not Throttle_Discontinuous then
               Add_Throttle_Events (Watch, Throttle_Increase);
            end if;
            if Time_Evidence.Availability = Condition_Available and then not Throttle_Time_Discontinuous then
               Add_Throttle_Time (Watch, Throttle_Time_Increase);
            end if;
            Watch.Throttle_Recovery_Unresolved :=
              Watch.Throttle_Recovery_Unresolved or else Throttle_Increase > 0;
            if Event_Evidence.Availability = Condition_Unavailable
              and then Previous.Throttle_Availability = Condition_Available
            then
               Current.Throttle_Availability := Condition_Unavailable;
            end if;
            if Time_Evidence.Availability = Condition_Unavailable
              and then Previous.Throttle_Time_Avail = Condition_Available
            then
               Current.Throttle_Time_Avail := Condition_Unavailable;
            end if;
         end;
         Record_Condition_Snapshot (Watch, Current);
         Current_Acceptable :=
           not Conditions_Unacceptable
                 (Config,
                  Watch,
                  Current,
                  Throttle_Increase,
                  Throttle_Time_Increase,
                  Throttle_Discontinuous,
                  Throttle_Time_Discontinuous);
         if not Current_Acceptable then
            Stable := 0;
         elsif Previous_Acceptable then
            Stable := Stable + (Now - Previous_Time);
         end if;
         Completed :=
           Natural'Min
             (100,
              Natural
                (Long_Float'Floor
                   (100.0 * Long_Float (Stable) / Long_Float'Max (1.0, Long_Float (Required)))));
         Notify (Config, Waiting_For_Operating_Conditions, Completed, 100);
         if Stable >= Required and then Now - Started <= Remaining_Budget then
            Recovered := True;
            exit;
         end if;
         exit when Now - Started >= Remaining_Budget;
         Previous := Current;
         Previous_Time := Now;
         Previous_Acceptable := Current_Acceptable;
      end loop;
      declare
         Spent : constant Interfaces.Unsigned_64 := Condition_Clock_Now - Started;
      begin
         Watch.Paused_Total := Watch.Paused_Total + Spent;
         Watch.Condition_Paused_Total := Watch.Condition_Paused_Total + Spent;
         Watch.Report.Condition_Paused_NS := Watch.Report.Condition_Paused_NS + Long_Float (Spent);
      end;
      if not Recovered then
         Watch.Report.Condition_Budget_Expired := True;
         Watch.Report.Condition_Fallback_Used := True;
         Watch.Throttle_Recovery_Unresolved := False;
         case Condition_Policy.Timeout_Action (Policy.On_Pause_Timeout) is
            when Condition_Policy.Policy_Accept =>
               null;

            when Condition_Policy.Policy_Fail   =>
               raise Operating_Conditions_Unacceptable with "operating conditions did not stabilize";

            when Condition_Policy.Policy_Pause  =>
               raise Program_Error with "invalid operating-condition timeout action";
         end case;
      else
         Watch.Throttle_Recovery_Unresolved := False;
      end if;
   end Await_Condition_Settle;

   procedure Prepare_Operating_Conditions (Config : Configuration; Watch : in out Interference_Watch) is
      Current   : Conditions.Snapshot;
      Recovered : Boolean;
   begin
      Watch.Conditions_Active := Mode (Config.Operating_Conditions) /= Disabled;
      if not Watch.Conditions_Active then
         return;
      end if;
      Watch.Report.Conditions_Checked := True;
      Read_Conditions (Watch, Current, Force_Profile => True);
      Watch.Condition_Last := Current;
      Record_Condition_Snapshot (Watch, Current, Initial => True);
      case Condition_Mode_Action
             (Mode (Config.Operating_Conditions),
              Conditions_Unacceptable
                (Config,
                 Watch,
                 Current,
                 Throttle_Discontinuous      => Current.Throttle_Discontinuous,
                 Throttle_Time_Discontinuous => Current.Throttle_Time_Discontinuous))
      is
         when Accept_Conditions    =>
            null;

         when Fail_Conditions      =>
            raise Operating_Conditions_Unacceptable with "initial operating conditions are unacceptable";

         when Pause_For_Conditions =>
            Await_Condition_Settle (Config, Watch, Recovered);
      end case;
   end Prepare_Operating_Conditions;

   procedure Establish_Operating_Baseline (Config : Configuration; Watch : in out Interference_Watch) is
      Current   : Conditions.Snapshot;
      Recovered : Boolean;
   begin
      if not Watch.Conditions_Active then
         return;
      end if;
      Read_Conditions (Watch, Current, Force_Profile => True);
      Record_Condition_Snapshot (Watch, Current);
      if Current.Process_Profile_Avail = Condition_Available then
         Watch.Process_Baseline := Current.Process_Profile;
      end if;
      case Condition_Mode_Action
             (Mode (Config.Operating_Conditions),
              Conditions_Unacceptable
                (Config,
                 Watch,
                 Current,
                 Throttle_Discontinuous      => Current.Throttle_Discontinuous,
                 Throttle_Time_Discontinuous => Current.Throttle_Time_Discontinuous))
      is
         when Accept_Conditions    =>
            null;

         when Fail_Conditions      =>
            raise Operating_Conditions_Unacceptable
              with "operating conditions after workload warmup are unacceptable";

         when Pause_For_Conditions =>
            Await_Condition_Settle (Config, Watch, Recovered);
            if Recovered and then Watch.Condition_Last.Process_Profile_Avail = Condition_Available then
               Watch.Process_Baseline := Watch.Condition_Last.Process_Profile;
            end if;
      end case;
   end Establish_Operating_Baseline;

   procedure Open_Condition_Window (Watch : in out Interference_Watch) is
      Current : Conditions.Snapshot;
   begin
      if not Watch.Conditions_Active then
         return;
      end if;
      Read_Conditions (Watch, Current);
      Watch.Condition_Start := Current;
      Record_Condition_Snapshot (Watch, Current);
      Watch.Condition_Open := True;
   end Open_Condition_Window;

   procedure Judge_Condition_Window
     (Config        : Configuration;
      Watch         : in out Interference_Watch;
      Units         : Positive;
      Action        : out Condition_Action;
      Count_Unit    : Boolean := True;
      Force_Profile : Boolean := False)
   is
      Current                     : Conditions.Snapshot;
      Throttle_Increase           : Interfaces.Unsigned_64 := 0;
      Throttle_Time_Increase      : Interfaces.Unsigned_64 := 0;
      Throttle_Discontinuous      : Boolean := False;
      Throttle_Time_Discontinuous : Boolean := False;
      Start_Unacceptable          : Boolean;
      Current_Unacceptable        : Boolean;
   begin
      Action := Accept_Conditions;
      if not Watch.Conditions_Active or else not Watch.Condition_Open then
         return;
      end if;
      Watch.Condition_Open := False;
      Read_Conditions (Watch, Current, Force_Profile => Force_Profile);
      declare
         Event_Evidence : constant Condition_Policy.Counter_Evidence :=
           Condition_Policy.Compare_Counter
             ((Availability => Watch.Condition_Start.Throttle_Availability,
               Value        => Watch.Condition_Start.Throttle_Total),
              (Availability => Current.Throttle_Availability, Value => Current.Throttle_Total));
         Time_Evidence  : constant Condition_Policy.Counter_Evidence :=
           Condition_Policy.Compare_Counter
             ((Availability => Watch.Condition_Start.Throttle_Time_Avail,
               Value        => Watch.Condition_Start.Throttle_Time_Total_MS),
              (Availability => Current.Throttle_Time_Avail, Value => Current.Throttle_Time_Total_MS));
      begin
         Throttle_Increase := Event_Evidence.Increase;
         Throttle_Time_Increase := Time_Evidence.Increase;
         Throttle_Discontinuous :=
           Event_Evidence.Discontinuous
           or else Watch.Condition_Start.Throttle_Discontinuous
           or else Current.Throttle_Discontinuous;
         Throttle_Time_Discontinuous :=
           Time_Evidence.Discontinuous
           or else Watch.Condition_Start.Throttle_Time_Discontinuous
           or else Current.Throttle_Time_Discontinuous;
         if Event_Evidence.Availability = Condition_Available and then not Throttle_Discontinuous then
            Add_Throttle_Events (Watch, Throttle_Increase);
         elsif Watch.Condition_Start.Throttle_Availability = Condition_Available
           or else Throttle_Discontinuous
         then
            Current.Throttle_Availability := Condition_Unavailable;
            Watch.Throttle_Report_Invalid := True;
            Watch.Report.Throttle_Availability := Condition_Unavailable;
         end if;
         if Time_Evidence.Availability = Condition_Available and then not Throttle_Time_Discontinuous then
            Add_Throttle_Time (Watch, Throttle_Time_Increase);
         elsif Watch.Condition_Start.Throttle_Time_Avail = Condition_Available
           or else Throttle_Time_Discontinuous
         then
            Current.Throttle_Time_Avail := Condition_Unavailable;
            Watch.Throttle_Time_Report_Invalid := True;
            Watch.Report.Throttle_Time_Avail := Condition_Unavailable;
         end if;
      end;
      Start_Unacceptable :=
        Conditions_Unacceptable
          (Config,
           Watch,
           Watch.Condition_Start,
           Throttle_Discontinuous      => Watch.Condition_Start.Throttle_Discontinuous,
           Throttle_Time_Discontinuous => Watch.Condition_Start.Throttle_Time_Discontinuous);
      Current_Unacceptable :=
        Conditions_Unacceptable
          (Config,
           Watch,
           Current,
           Throttle_Increase,
           Throttle_Time_Increase,
           Throttle_Discontinuous,
           Throttle_Time_Discontinuous);
      Record_Condition_Snapshot (Watch, Current);
      if Count_Unit then
         Watch.Report.Condition_Windows := Watch.Report.Condition_Windows + 1;
      end if;
      if not Condition_Policy.Window_Unacceptable (Start_Unacceptable, Current_Unacceptable) then
         return;
      end if;
      if Count_Unit then
         Watch.Report.Affected_Units := Watch.Report.Affected_Units + Units;
      end if;
      Action := Condition_Mode_Action (Mode (Config.Operating_Conditions), Rejected => True);
      Watch.Throttle_Recovery_Unresolved := Action = Pause_For_Conditions and then Throttle_Increase > 0;
   end Judge_Condition_Window;

   procedure Validate_After_Calibration
     (Config : Configuration; Watch : in out Interference_Watch; Recalibrate : out Boolean)
   is
      Action    : Condition_Action;
      Recovered : Boolean;
   begin
      Recalibrate := False;
      Judge_Condition_Window (Config, Watch, 1, Action, Count_Unit => False, Force_Profile => True);
      case Action is
         when Accept_Conditions    =>
            null;

         when Fail_Conditions      =>
            raise Operating_Conditions_Unacceptable with "operating conditions changed during calibration";

         when Pause_For_Conditions =>
            Await_Condition_Settle (Config, Watch, Recovered);
            Recalibrate := Recovered;
      end case;
   end Validate_After_Calibration;

   procedure Finalize_Operating_Conditions (Watch : in out Interference_Watch) is
      Current : constant Conditions.Snapshot := Watch.Condition_Last;
   begin
      if not Watch.Conditions_Active then
         return;
      end if;
      --  A sampling window's forced closing read has already been judged.
      --  Re-reading here would discover a state too late for Pause or Fail to
      --  reject the affected window.
      Record_Condition_Snapshot (Watch, Current, Final => True);
   end Finalize_Operating_Conditions;

   --  Number of collection units judged together. Interference or operating-
   --  condition watching is the only reason to group units at all; without
   --  either, every unit is judged alone and the collection loop keeps its
   --  original shape.
   function Units_Per_Window
     (Config : Configuration; Unit_Nanoseconds : Long_Float; Total_Units : Positive) return Positive
   is
      Required : Long_Float;
      Units    : Long_Float;
   begin
      if (not Config.Interference.Enabled and then Mode (Config.Operating_Conditions) = Disabled)
        or else Unit_Nanoseconds <= 0.0
      then
         return 1;
      end if;
      Required :=
        Long_Float
          (Duration_Nanoseconds
             (Window_Policy.Required_Window
                ((if Config.Interference.Enabled then Config.Interference.Window else 0.0),
                 (if Mode (Config.Operating_Conditions) /= Disabled
                  then Config.Operating_Conditions.Window
                  else 0.0))));
      --  Batch duration varies from sample to sample, so a window sized to
      --  only just reach the minimum would regularly fall short of it and
      --  silently degrade to observation. The margin buys that back.
      Units := Long_Float'Max (1.0, Long_Float'Ceiling (1.25 * Required / Unit_Nanoseconds));
      if Units >= Long_Float (Total_Units) then
         return Total_Units;
      end if;
      return Positive (Units);
   end Units_Per_Window;

   procedure Apply_Environment
     (Watch : Interference_Watch; Result : in out Measurement; Include_Samples : Boolean := True) is
   begin
      Result.Environment_Data := Watch.Report;
      if Include_Samples then
         Result.Foreign_CPU := Watch.Foreign;
      end if;
      if Watch.Report.Windows > 0 then
         Result.Environment_Data.Mean_Foreign_CPU_Percent :=
           Watch.Foreign_Sum / Long_Float (Watch.Report.Windows);
      end if;
   end Apply_Environment;

   procedure Add_Watched_CPU (Watch : in out Interference_Watch; CPU : Natural) is
   begin
      for Index in 1 .. Watch.Watched_Total loop
         if Watch.Watched (Index) = CPU then
            return;
         end if;
      end loop;
      if Watch.Watched_Total < Maximum_Watched_CPUs then
         Watch.Watched_Total := Watch.Watched_Total + 1;
         Watch.Watched (Watch.Watched_Total) := CPU;
      end if;
   end Add_Watched_CPU;

   --  First line of a Linux pseudo-file, or the empty string when it cannot
   --  be read. Placement inspection is Linux-only, so an absent file is an
   --  ordinary answer rather than an error.
   function Read_First_Line (Path : String) return String is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      declare
         Line : constant String := Ada.Text_IO.Get_Line (File);
      begin
         Ada.Text_IO.Close (File);
         return Line;
      end;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return "";
   end Read_First_Line;

   --  /proc pads its fields with tabs, which Ada.Strings.Fixed.Trim does not
   --  remove by default. A retained tab makes Natural'Value raise, and the
   --  CPU list then parses as empty.
   Blanks : constant Ada.Strings.Maps.Character_Set :=
     Ada.Strings.Maps.To_Set (' ' & ASCII.HT & ASCII.CR & ASCII.LF);

   function Unpadded (Value : String) return String
   is (Ada.Strings.Fixed.Trim (Value, Blanks, Blanks));

   --  Value of one /proc/self/status field, without its name or padding.
   function Status_Field (Name : String) return String is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, "/proc/self/status");
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
         begin
            if Line'Length > Name'Length + 1
              and then Line (Line'First .. Line'First + Name'Length) = Name & ":"
            then
               declare
                  Value : constant String := Unpadded (Line (Line'First + Name'Length + 1 .. Line'Last));
               begin
                  Ada.Text_IO.Close (File);
                  return Value;
               end;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
      return "";
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return "";
   end Status_Field;

   --  Add every CPU named by a Linux list such as "0-3,8,10-11".
   procedure Add_CPU_List (Watch : in out Interference_Watch; Text : String) is
      First : Natural := Text'First;
   begin
      while First <= Text'Last loop
         declare
            Last : Natural := Text'Last;
            Dash : Natural := 0;
            Low  : Natural;
            High : Natural;
         begin
            for Index in First .. Text'Last loop
               if Text (Index) = ',' then
                  Last := Index - 1;
                  exit;
               end if;
            end loop;
            for Index in First .. Last loop
               if Text (Index) = '-' then
                  Dash := Index;
                  exit;
               end if;
            end loop;
            begin
               if Dash > 0 then
                  Low := Natural'Value (Unpadded (Text (First .. Dash - 1)));
                  High := Natural'Value (Unpadded (Text (Dash + 1 .. Last)));
               else
                  Low := Natural'Value (Unpadded (Text (First .. Last)));
                  High := Low;
               end if;
               for CPU in Low .. High loop
                  Add_Watched_CPU (Watch, CPU);
               end loop;
            exception
               when Constraint_Error =>
                  null;
            end;
            First := Last + 2;
         end;
      end loop;
   end Add_CPU_List;

   --  Build the set of logical CPUs whose busy time is entirely foreign. SMT
   --  siblings belong in it: a sibling saturated by another process slows the
   --  measurement while leaving the placed CPU's own busy share clean.
   procedure Collect_Watched_CPUs (Config : Configuration; Watch : in out Interference_Watch) is
      Allowed : constant String := Status_Field ("Cpus_allowed_list");
      Placed  : Natural;
   begin
      if Allowed = "" then
         return;
      end if;
      Add_CPU_List (Watch, Allowed);
      if not Config.Placement.Include_Siblings then
         return;
      end if;
      Placed := Watch.Watched_Total;
      for Index in 1 .. Placed loop
         Add_CPU_List
           (Watch,
            Read_First_Line
              ("/sys/devices/system/cpu/cpu"
               & Ada.Strings.Fixed.Trim (Natural'Image (Watch.Watched (Index)), Ada.Strings.Both)
               & "/topology/thread_siblings_list"));
      end loop;
   end Collect_Watched_CPUs;

   --  Claim host CPU capacity, place the benchmark thread, and decide how
   --  foreign load will be attributed. Runs before the preflight gate: a
   --  quiet verdict obtained before blocking on the claim would be stale by
   --  the time collection started.
   procedure Prepare_Environment
     (Config : Configuration; Watch : in out Interference_Watch; Lock : in out Host_Lock.Claim)
   is
      use type Host_Lock.Acquisition;
      use type Host_Lock.Path_Isolation;
      use type Host_Control.Placement_Strength;
   begin
      if Config.Host_Lock.Enabled then
         declare
            Path    : constant String := Ada.Strings.Unbounded.To_String (Config.Host_Lock.Path);
            Step    : constant Duration := Duration'Max (0.001, Config.Host_Lock.Poll_Interval);
            Waited  : Duration := 0.0;
            Outcome : Host_Lock.Acquisition;
         begin
            Notify (Config, Waiting_For_CPU_Quiescence, 0, 100);
            loop
               Host_Lock.Try_Acquire (Lock, Outcome, Path => Path);
               exit when Outcome /= Host_Lock.Busy;
               exit when Waited >= Config.Host_Lock.Timeout;
               --  Waiting idle rather than spinning: a busy waiter would be
               --  the very foreign load the holder is trying to avoid.
               delay Step;
               Waited := Waited + Step;
               Notify
                 (Config,
                  Waiting_For_CPU_Quiescence,
                  (if Config.Host_Lock.Timeout > 0.0
                   then
                     Natural'Min
                       (100,
                        Natural
                          (Long_Float'Floor
                             (100.0 * Long_Float (Waited) / Long_Float (Config.Host_Lock.Timeout))))
                   else 100),
                  100);
            end loop;
            case Outcome is
               when Host_Lock.Acquired      =>
                  Watch.Report.Host_Lock :=
                    (if Host_Lock.Isolation (Lock) = Host_Lock.Private_Namespace
                     then Lock_Namespace_Scoped
                     else Lock_Held);

               when Host_Lock.Busy          =>
                  Watch.Report.Host_Lock := Lock_Busy;

               when Host_Lock.Path_Unusable =>
                  Watch.Report.Host_Lock := Lock_Path_Unusable;
            end case;
         end;
         if Config.Host_Lock.Require_Machine_Scope and then Watch.Report.Host_Lock /= Lock_Held then
            raise Host_Lock_Unavailable
              with
                "host CPU claim is not machine-wide ("
                & Host_Lock_Outcome'Image (Watch.Report.Host_Lock)
                & ")";
         end if;
      end if;

      if Config.Placement.Enabled then
         begin
            Watch.Report.Placement :=
              (if Host_Control.Pin_Current_Thread (Config.Placement.CPU) = Host_Control.Strict
               then Placement_Strict
               else Placement_Advisory);
         exception
            when Program_Error =>
               Watch.Report.Placement := Placement_Rejected;
         end;
         if Config.Placement.Require_Strict and then Watch.Report.Placement /= Placement_Strict then
            raise Placement_Unavailable with "strict benchmark thread placement is unavailable on this host";
         end if;
         --  Only a strict binding tells us which CPUs are ours. A Darwin
         --  affinity tag is a scheduler hint whose value is not a CPU index,
         --  so attribution there stays host-wide.
         if Watch.Report.Placement = Placement_Strict then
            Collect_Watched_CPUs (Config, Watch);
         end if;
      end if;

      if Watch.Watched_Total > 0 then
         Watch.Report.Attribution := Core_Scoped;
         Watch.Report.Watched_CPUs := Watch.Watched_Total;
      else
         Watch.Report.Attribution := Host_Wide;
      end if;
      Watch.Active := Config.Interference.Enabled;
   end Prepare_Environment;

   procedure Await_CPU_Quiescence (Config : Configuration) is
      Previous_Busy  : Host_CPU_Counters := [others => 0];
      Previous_Total : Host_CPU_Counters := [others => 0];
      Current_Busy   : Host_CPU_Counters := [others => 0];
      Current_Total  : Host_CPU_Counters := [others => 0];
      Previous_Count : Natural;
      Current_Count  : Natural;
      Started        : Interfaces.Unsigned_64;
      Previous_Time  : Interfaces.Unsigned_64;
      Current_Time   : Interfaces.Unsigned_64;
      Stable_NS      : Interfaces.Unsigned_64 := 0;
      Required_NS    : Interfaces.Unsigned_64;
      Timeout_NS     : Interfaces.Unsigned_64;
      Average        : Long_Float := 0.0;
      Peak           : Long_Float := 0.0;
      Available      : Boolean;
      Completed      : Natural;
   begin
      if not Config.CPU_Quiescence.Enabled then
         return;
      end if;

      Required_NS := Duration_Nanoseconds (Config.CPU_Quiescence.Stable_Time);
      Timeout_NS := Duration_Nanoseconds (Config.CPU_Quiescence.Timeout);
      Read_Host_CPU (Previous_Busy, Previous_Total, Previous_Count);
      Started := Clock_Now;
      Previous_Time := Started;
      Notify (Config, Waiting_For_CPU_Quiescence, 0, 100);

      loop
         delay Config.CPU_Quiescence.Poll_Interval;
         Read_Host_CPU (Current_Busy, Current_Total, Current_Count);
         Current_Time := Clock_Now;
         if Current_Count = Previous_Count then
            Host_CPU_Utilization
              (Previous_Busy,
               Previous_Total,
               Current_Busy,
               Current_Total,
               Current_Count,
               Average,
               Peak,
               Available);
         else
            Available := False;
         end if;

         if Available
           and then Average <= Config.CPU_Quiescence.Maximum_Average_CPU_Percent
           and then Peak <= Config.CPU_Quiescence.Maximum_Core_CPU_Percent
         then
            Stable_NS := Stable_NS + (Current_Time - Previous_Time);
         else
            Stable_NS := 0;
         end if;

         Completed :=
           Natural'Min
             (100, Natural (Long_Float'Floor (100.0 * Long_Float (Stable_NS) / Long_Float (Required_NS))));
         Notify (Config, Waiting_For_CPU_Quiescence, Completed, 100);
         exit when Stable_NS >= Required_NS;

         if Current_Time - Started >= Timeout_NS then
            raise CPU_Quiescence_Timeout
              with
                "host CPU did not remain below the configured limits"
                & " (last average"
                & Long_Float'Image (Average)
                & "%, peak"
                & Long_Float'Image (Peak)
                & "%)";
         end if;

         Previous_Busy := Current_Busy;
         Previous_Total := Current_Total;
         Previous_Count := Current_Count;
         Previous_Time := Current_Time;
      end loop;
   end Await_CPU_Quiescence;

   procedure Characterize_Clock
     (Backend             : out Natural;
      Nominal_Resolution  : out Long_Float;
      Observed_Resolution : out Long_Float;
      Minimum_Cost        : out Long_Float;
      Median_Cost         : out Long_Float)
   is
      Count      : constant := 512;
      Resolution : Interfaces.Unsigned_64;
      Available  : Boolean;
      Values     : Float_Array (1 .. Count);
      Previous   : Interfaces.Unsigned_64 := Clock_Now;
   begin
      Read_Clock_Resolution (Resolution, Available);
      if not Available then
         raise Program_Error with "platform clock resolution query failed";
      end if;
      Backend := Clock_Backend;
      Nominal_Resolution := Long_Float (Resolution);
      Observed_Resolution := Long_Float'Last;
      Minimum_Cost := Long_Float'Last;
      for Index in Values'Range loop
         declare
            Current : constant Interfaces.Unsigned_64 := Clock_Now;
            Elapsed : constant Long_Float := Elapsed_Nanoseconds (Previous, Current);
         begin
            Values (Index) := Elapsed;
            if Elapsed > 0.0 then
               Observed_Resolution := Long_Float'Min (Observed_Resolution, Elapsed);
               Minimum_Cost := Long_Float'Min (Minimum_Cost, Elapsed);
            end if;
            Previous := Current;
         end;
      end loop;
      Sort (Values);
      Median_Cost := Percentile (Values, 0.5);
      if Observed_Resolution = Long_Float'Last then
         Observed_Resolution := 0.0;
      end if;
      if Minimum_Cost = Long_Float'Last then
         Minimum_Cost := 0.0;
      end if;
   end Characterize_Clock;

   function Next_Random (State : in out Interfaces.Unsigned_64) return Interfaces.Unsigned_64 is
   begin
      State := State xor Interfaces.Shift_Left (State, 13);
      State := State xor Interfaces.Shift_Right (State, 7);
      State := State xor Interfaces.Shift_Left (State, 17);
      return State;
   end Next_Random;

   procedure Analyze (Result : in out Measurement) is
      Count      : constant Positive := Positive (Result.Sample_Total);
      Ordered    : Float_Array (1 .. Count);
      Deviations : Float_Array (1 .. Count);
      Sum        : Long_Float := 0.0;
      Sum_Square : Long_Float := 0.0;
      Q1         : Long_Float;
      Q3         : Long_Float;
      IQR        : Long_Float;
   begin
      for Index in Ordered'Range loop
         Ordered (Index) := Result.Values (Sample_Index (Index));
         Sum := Sum + Ordered (Index);
      end loop;
      Sort (Ordered);

      Result.Minimum := Ordered (Ordered'First);
      Result.Maximum := Ordered (Ordered'Last);
      Result.Mean := Sum / Long_Float (Count);
      Result.Median := Percentile (Ordered, 0.5);
      Result.P95 := Percentile (Ordered, 0.95);
      Result.P99 := Percentile (Ordered, 0.99);

      for Index in Ordered'Range loop
         declare
            Difference : constant Long_Float := Ordered (Index) - Result.Mean;
         begin
            Sum_Square := Sum_Square + Difference * Difference;
            Deviations (Index) := abs (Ordered (Index) - Result.Median);
         end;
      end loop;
      Sort (Deviations);
      Result.MAD := Percentile (Deviations, 0.5);
      Result.Standard_Deviation := Math.Sqrt (Sum_Square / Long_Float (Count - 1));
      if Result.Mean /= 0.0 then
         Result.CV_Percent := 100.0 * Result.Standard_Deviation / Result.Mean;
      end if;

      if Count > 2 then
         declare
            Numerator : Long_Float := 0.0;
            Left_Sum  : Long_Float := 0.0;
            Right_Sum : Long_Float := 0.0;
         begin
            for Index in 2 .. Count loop
               declare
                  Left  : constant Long_Float := Result.Values (Sample_Index (Index - 1)) - Result.Mean;
                  Right : constant Long_Float := Result.Values (Sample_Index (Index)) - Result.Mean;
               begin
                  Numerator := Numerator + Left * Right;
                  Left_Sum := Left_Sum + Left * Left;
                  Right_Sum := Right_Sum + Right * Right;
               end;
            end loop;
            if Left_Sum > 0.0 and then Right_Sum > 0.0 then
               Result.Lag_One := Numerator / Math.Sqrt (Left_Sum * Right_Sum);
            end if;
         end;
      end if;

      Q1 := Percentile (Ordered, 0.25);
      Q3 := Percentile (Ordered, 0.75);
      IQR := Q3 - Q1;
      for Index in Ordered'Range loop
         if Ordered (Index) < Q1 - 3.0 * IQR then
            Result.Outlier_Total.Low_Severe := Result.Outlier_Total.Low_Severe + 1;
         elsif Ordered (Index) < Q1 - 1.5 * IQR then
            Result.Outlier_Total.Low_Mild := Result.Outlier_Total.Low_Mild + 1;
         elsif Ordered (Index) > Q3 + 3.0 * IQR then
            Result.Outlier_Total.High_Severe := Result.Outlier_Total.High_Severe + 1;
         elsif Ordered (Index) > Q3 + 1.5 * IQR then
            Result.Outlier_Total.High_Mild := Result.Outlier_Total.High_Mild + 1;
         end if;
      end loop;

      declare
         Means        : Float_Array (1 .. Result.Bootstrap_Resample_Total);
         State        : Interfaces.Unsigned_64 :=
           16#9E37_79B9_7F4A_7C15# xor Interfaces.Unsigned_64 (Result.Random_Seed_Value);
         Block_Length : constant Positive :=
           Positive'Max (2, Positive (Long_Float'Ceiling (Math.Sqrt (Long_Float (Count)))));
      begin
         for Resample in Means'Range loop
            Sum := 0.0;
            declare
               Drawn : Natural := 0;
            begin
               while Drawn < Count loop
                  declare
                     Start : constant Positive :=
                       Positive (Natural (Next_Random (State) mod Interfaces.Unsigned_64 (Count)) + 1);
                  begin
                     for Offset in 0 .. Block_Length - 1 loop
                        exit when Drawn = Count;
                        declare
                           Index : constant Positive := ((Start - 1 + Offset) mod Count) + 1;
                        begin
                           Sum := Sum + Result.Values (Sample_Index (Index));
                           Drawn := Drawn + 1;
                        end;
                     end loop;
                  end;
               end loop;
            end;
            Means (Resample) := Sum / Long_Float (Count);
         end loop;
         Sort (Means);
         Result.Confidence_Low := Percentile (Means, Lower_Tail (Result.Confidence_Level_Value));
         Result.Confidence_High := Percentile (Means, 1.0 - Lower_Tail (Result.Confidence_Level_Value));
      end;
   end Analyze;

   procedure Analyze_Metrics (Result : in out Measurement) is
   begin
      if Result.Metric_Data.Data = null then
         return;
      end if;
      for Axis in Metric_Axis loop
         if Result.Metric_Data.Data.Requested (Axis) and then Result.Metric_Data.Data.Available (Axis) then
            declare
               Count        : constant Positive := Positive (Result.Sample_Total);
               Ordered      : Float_Array (1 .. Count);
               Means        : Float_Array (1 .. Result.Bootstrap_Resample_Total);
               Sum          : Long_Float := 0.0;
               State        : Interfaces.Unsigned_64 :=
                 16#243F_6A88_85A3_08D3#
                 xor Interfaces.Unsigned_64 (Result.Random_Seed_Value)
                 xor Interfaces.Unsigned_64 (Metric_Axis'Pos (Axis) + 1);
               Block_Length : constant Positive :=
                 Positive'Max (2, Positive (Long_Float'Ceiling (Math.Sqrt (Long_Float (Count)))));
               Summary      : Metric_Summary;
            begin
               for Sample in Ordered'Range loop
                  Ordered (Sample) := Result.Metric_Data.Data.Values (Axis, Sample_Index (Sample));
                  Sum := Sum + Ordered (Sample);
               end loop;
               Sort (Ordered);
               Summary.Available := True;
               Summary.Samples := Count;
               Summary.Minimum := Ordered (Ordered'First);
               Summary.Maximum := Ordered (Ordered'Last);
               Summary.Mean := Sum / Long_Float (Count);
               Summary.Median := Percentile (Ordered, 0.5);
               Summary.P95 := Percentile (Ordered, 0.95);
               Summary.P99 := Percentile (Ordered, 0.99);

               for Resample in Means'Range loop
                  Sum := 0.0;
                  declare
                     Drawn : Natural := 0;
                  begin
                     while Drawn < Count loop
                        declare
                           Start : constant Positive :=
                             Positive (Natural (Next_Random (State) mod Interfaces.Unsigned_64 (Count)) + 1);
                        begin
                           for Offset in 0 .. Block_Length - 1 loop
                              exit when Drawn = Count;
                              declare
                                 Sample : constant Positive := ((Start - 1 + Offset) mod Count) + 1;
                              begin
                                 Sum := Sum + Result.Metric_Data.Data.Values (Axis, Sample_Index (Sample));
                                 Drawn := Drawn + 1;
                              end;
                           end loop;
                        end;
                     end loop;
                  end;
                  Means (Resample) := Sum / Long_Float (Count);
               end loop;
               Sort (Means);
               Summary.Confidence_Low := Percentile (Means, Lower_Tail (Result.Confidence_Level_Value));
               Summary.Confidence_High :=
                 Percentile (Means, 1.0 - Lower_Tail (Result.Confidence_Level_Value));
               Result.Metric_Data.Data.Summaries (Axis) := Summary;
            end;
         end if;
      end loop;
   end Analyze_Metrics;

   procedure Analyze_Custom_Metrics (Result : in out Measurement) is
   begin
      if Result.Custom_Data.Data = null then
         return;
      end if;
      for Axis in 1 .. Result.Custom_Data.Data.Count loop
         declare
            Available_Count : Natural := 0;
         begin
            for Sample in 1 .. Result.Sample_Total loop
               if Result.Custom_Data.Data.Status (Axis, Sample) = Metric_Collected then
                  Available_Count := Available_Count + 1;
               end if;
            end loop;
            if Available_Count > 0 then
               declare
                  Samples      : Float_Array (1 .. Available_Count);
                  Ordered      : Float_Array (1 .. Available_Count);
                  Means        : Float_Array (1 .. Result.Bootstrap_Resample_Total);
                  Sum          : Long_Float := 0.0;
                  Next         : Natural := 0;
                  State        : Interfaces.Unsigned_64 :=
                    16#9E37_79B9_7F4A_7C15#
                    xor Interfaces.Unsigned_64 (Result.Random_Seed_Value)
                    xor Interfaces.Unsigned_64 (Axis);
                  Block_Length : constant Positive :=
                    Positive'Max
                      (2, Positive (Long_Float'Ceiling (Math.Sqrt (Long_Float (Available_Count)))));
                  Summary      : Metric_Summary;
               begin
                  for Sample in 1 .. Result.Sample_Total loop
                     if Result.Custom_Data.Data.Status (Axis, Sample) = Metric_Collected then
                        Next := Next + 1;
                        Samples (Next) := Result.Custom_Data.Data.Values (Axis, Sample);
                        Ordered (Next) := Samples (Next);
                        Sum := Sum + Samples (Next);
                     end if;
                  end loop;
                  Sort (Ordered);
                  Summary.Available := True;
                  Summary.Samples := Available_Count;
                  Summary.Minimum := Ordered (1);
                  Summary.Maximum := Ordered (Available_Count);
                  Summary.Mean := Sum / Long_Float (Available_Count);
                  Summary.Median := Percentile (Ordered, 0.5);
                  Summary.P95 := Percentile (Ordered, 0.95);
                  Summary.P99 := Percentile (Ordered, 0.99);
                  for Resample in Means'Range loop
                     Sum := 0.0;
                     declare
                        Drawn : Natural := 0;
                     begin
                        while Drawn < Available_Count loop
                           declare
                              Start : constant Positive :=
                                Positive
                                  (Natural (Next_Random (State) mod Interfaces.Unsigned_64 (Available_Count))
                                   + 1);
                           begin
                              for Offset in 0 .. Block_Length - 1 loop
                                 exit when Drawn = Available_Count;
                                 Sum := Sum + Samples (((Start - 1 + Offset) mod Available_Count) + 1);
                                 Drawn := Drawn + 1;
                              end loop;
                           end;
                        end loop;
                     end;
                     Means (Resample) := Sum / Long_Float (Available_Count);
                  end loop;
                  Sort (Means);
                  Summary.Confidence_Low := Percentile (Means, Lower_Tail (Result.Confidence_Level_Value));
                  Summary.Confidence_High :=
                    Percentile (Means, 1.0 - Lower_Tail (Result.Confidence_Level_Value));
                  Result.Custom_Data.Data.Summaries (Axis) := Summary;
               end;
            end if;
         end;
      end loop;
   end Analyze_Custom_Metrics;

   procedure Analyze_Custom_Comparisons (Result : in out Comparison) is
      Count : constant Positive := Positive (Result.Reference_Data.Sample_Total);
   begin
      if Result.Reference_Data.Custom_Data.Data = null or else Result.Contender_Data.Custom_Data.Data = null
      then
         return;
      end if;
      for Axis in
        1
        .. Custom_Metric_Count'Min
             (Result.Reference_Data.Custom_Data.Data.Count, Result.Contender_Data.Custom_Data.Data.Count)
      loop
         declare
            Descriptor : constant Custom_Metric_Descriptor :=
              Result.Reference_Data.Custom_Data.Data.Descriptors (Axis);
            Complete   : Boolean := True;
         begin
            for Sample in 1 .. Count loop
               Complete :=
                 Complete
                 and then Result.Reference_Data.Custom_Data.Data.Status (Axis, Sample) = Metric_Collected
                 and then Result.Contender_Data.Custom_Data.Data.Status (Axis, Sample) = Metric_Collected;
            end loop;
            if Complete then
               declare
                  Samples      : Float_Array (1 .. Count);
                  Bootstrap    : Float_Array (1 .. Result.Reference_Data.Bootstrap_Resample_Total);
                  State        : Interfaces.Unsigned_64 :=
                    16#D1B5_4A32_D192_ED03#
                    xor Interfaces.Unsigned_64 (Result.Random_Seed_Value)
                    xor Interfaces.Unsigned_64 (Axis);
                  Block_Length : constant Positive :=
                    Positive'Max (2, Positive (Long_Float'Ceiling (Math.Sqrt (Long_Float (Count)))));
                  Sum          : Long_Float := 0.0;
                  Item         : Metric_Comparison_Result;
               begin
                  Item.Available := True;
                  Item.Reference_Median := Result.Reference_Data.Custom_Data.Data.Summaries (Axis).Median;
                  Item.Contender_Median := Result.Contender_Data.Custom_Data.Data.Summaries (Axis).Median;
                  Item.Method :=
                    (if Descriptor.Comparison_Value = Relative_Positive
                     then Relative_Ratio
                     else Absolute_Difference);
                  for Sample in Samples'Range loop
                     declare
                        Reference_Value : constant Long_Float :=
                          Result.Reference_Data.Custom_Data.Data.Values (Axis, Sample_Index (Sample));
                        Contender_Value : constant Long_Float :=
                          Result.Contender_Data.Custom_Data.Data.Values (Axis, Sample_Index (Sample));
                     begin
                        if Item.Method = Relative_Ratio then
                           if Reference_Value <= 0.0 or else Contender_Value <= 0.0 then
                              Complete := False;
                              exit;
                           end if;
                           Samples (Sample) := Math.Log (Contender_Value / Reference_Value);
                        else
                           Samples (Sample) := Contender_Value - Reference_Value;
                        end if;
                        Sum := Sum + Samples (Sample);
                     end;
                  end loop;
                  if Complete then
                     Item.Change :=
                       (if Item.Method = Relative_Ratio
                        then 100.0 * (Math.Exp (Sum / Long_Float (Count)) - 1.0)
                        else Sum / Long_Float (Count));
                     for Resample in Bootstrap'Range loop
                        Sum := 0.0;
                        declare
                           Drawn : Natural := 0;
                        begin
                           while Drawn < Count loop
                              declare
                                 Start : constant Positive :=
                                   Positive
                                     (Natural (Next_Random (State) mod Interfaces.Unsigned_64 (Count)) + 1);
                              begin
                                 for Offset in 0 .. Block_Length - 1 loop
                                    exit when Drawn = Count;
                                    Sum := Sum + Samples (((Start - 1 + Offset) mod Count) + 1);
                                    Drawn := Drawn + 1;
                                 end loop;
                              end;
                           end loop;
                        end;
                        Bootstrap (Resample) :=
                          (if Item.Method = Relative_Ratio
                           then 100.0 * (Math.Exp (Sum / Long_Float (Count)) - 1.0)
                           else Sum / Long_Float (Count));
                     end loop;
                     Sort (Bootstrap);
                     Item.Confidence_Low :=
                       Percentile (Bootstrap, Lower_Tail (Result.Reference_Data.Confidence_Level_Value));
                     Item.Confidence_High :=
                       Percentile
                         (Bootstrap, 1.0 - Lower_Tail (Result.Reference_Data.Confidence_Level_Value));
                     if Descriptor.Direction_Value = Diagnostic then
                        Item.Verdict := Metric_Diagnostic;
                     elsif Item.Method = Relative_Ratio
                       and then Item.Confidence_Low >= -Result.Practical_Threshold
                       and then Item.Confidence_High <= Result.Practical_Threshold
                     then
                        Item.Verdict := Metric_Practically_Equivalent;
                     elsif Item.Confidence_Low = 0.0 and then Item.Confidence_High = 0.0 then
                        Item.Verdict := Metric_Practically_Equivalent;
                     elsif Descriptor.Direction_Value = Lower_Is_Better
                       and then Item.Confidence_High < -Result.Practical_Threshold
                     then
                        Item.Verdict := Contender_Better;
                     elsif Descriptor.Direction_Value = Lower_Is_Better
                       and then Item.Confidence_Low > Result.Practical_Threshold
                     then
                        Item.Verdict := Reference_Better;
                     elsif Descriptor.Direction_Value = Higher_Is_Better
                       and then Item.Confidence_Low > Result.Practical_Threshold
                     then
                        Item.Verdict := Contender_Better;
                     elsif Descriptor.Direction_Value = Higher_Is_Better
                       and then Item.Confidence_High < -Result.Practical_Threshold
                     then
                        Item.Verdict := Reference_Better;
                     end if;
                     Result.Custom_Comparisons (Axis) := Item;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Analyze_Custom_Comparisons;

   procedure Analyze_Metric_Comparisons (Result : in out Comparison) is
      Count : constant Positive := Positive (Result.Reference_Data.Sample_Total);
   begin
      for Axis in Metric_Axis loop
         if Result.Reference_Data.Metric_Data.Data /= null
           and then Result.Contender_Data.Metric_Data.Data /= null
           and then Result.Reference_Data.Metric_Data.Data.Available (Axis)
           and then Result.Contender_Data.Metric_Data.Data.Available (Axis)
           and then Result.Reference_Data.Metric_Data.Data.Requested (Axis)
           and then Result.Contender_Data.Metric_Data.Data.Requested (Axis)
         then
            declare
               Samples       : Float_Array (1 .. Count);
               Bootstrap     : Float_Array (1 .. Result.Reference_Data.Bootstrap_Resample_Total);
               Positive_Only : Boolean := True;
               Sum           : Long_Float := 0.0;
               State         : Interfaces.Unsigned_64 :=
                 16#1319_8A2E_0370_7344#
                 xor Interfaces.Unsigned_64 (Result.Random_Seed_Value)
                 xor Interfaces.Unsigned_64 (Metric_Axis'Pos (Axis) + 1);
               Block_Length  : constant Positive :=
                 Positive'Max (2, Positive (Long_Float'Ceiling (Math.Sqrt (Long_Float (Count)))));
               Item          : Metric_Comparison_Result;
            begin
               Item.Available := True;
               Item.Reference_Median := Result.Reference_Data.Metric_Data.Data.Summaries (Axis).Median;
               Item.Contender_Median := Result.Contender_Data.Metric_Data.Data.Summaries (Axis).Median;
               for Sample in Samples'Range loop
                  if Result.Reference_Data.Metric_Data.Data.Values (Axis, Sample_Index (Sample)) <= 0.0
                    or else Result.Contender_Data.Metric_Data.Data.Values (Axis, Sample_Index (Sample)) <= 0.0
                  then
                     Positive_Only := False;
                  end if;
               end loop;

               if Positive_Only then
                  Item.Method := Relative_Ratio;
                  for Sample in Samples'Range loop
                     Samples (Sample) :=
                       Math.Log
                         (Result.Contender_Data.Metric_Data.Data.Values (Axis, Sample_Index (Sample))
                          / Result.Reference_Data.Metric_Data.Data.Values (Axis, Sample_Index (Sample)));
                     Sum := Sum + Samples (Sample);
                  end loop;
                  Item.Change := 100.0 * (Math.Exp (Sum / Long_Float (Count)) - 1.0);
               else
                  Item.Method := Absolute_Difference;
                  for Sample in Samples'Range loop
                     Samples (Sample) :=
                       Result.Contender_Data.Metric_Data.Data.Values (Axis, Sample_Index (Sample))
                       - Result.Reference_Data.Metric_Data.Data.Values (Axis, Sample_Index (Sample));
                     Sum := Sum + Samples (Sample);
                  end loop;
                  Item.Change := Sum / Long_Float (Count);
               end if;

               for Resample in Bootstrap'Range loop
                  Sum := 0.0;
                  declare
                     Drawn : Natural := 0;
                  begin
                     while Drawn < Count loop
                        declare
                           Start : constant Positive :=
                             Positive (Natural (Next_Random (State) mod Interfaces.Unsigned_64 (Count)) + 1);
                        begin
                           for Offset in 0 .. Block_Length - 1 loop
                              exit when Drawn = Count;
                              Sum := Sum + Samples (((Start - 1 + Offset) mod Count) + 1);
                              Drawn := Drawn + 1;
                           end loop;
                        end;
                     end loop;
                  end;
                  if Item.Method = Relative_Ratio then
                     Bootstrap (Resample) := 100.0 * (Math.Exp (Sum / Long_Float (Count)) - 1.0);
                  else
                     Bootstrap (Resample) := Sum / Long_Float (Count);
                  end if;
               end loop;
               Sort (Bootstrap);
               Item.Confidence_Low :=
                 Percentile (Bootstrap, Lower_Tail (Result.Reference_Data.Confidence_Level_Value));
               Item.Confidence_High :=
                 Percentile (Bootstrap, 1.0 - Lower_Tail (Result.Reference_Data.Confidence_Level_Value));

               if Direction (Axis) = Diagnostic then
                  Item.Verdict := Metric_Diagnostic;
               elsif Item.Method = Relative_Ratio then
                  declare
                     Threshold : constant Long_Float := Result.Practical_Threshold;
                  begin
                     if Item.Confidence_Low >= -Threshold and then Item.Confidence_High <= Threshold then
                        Item.Verdict := Metric_Practically_Equivalent;
                     elsif Direction (Axis) = Lower_Is_Better and then Item.Confidence_High < -Threshold then
                        Item.Verdict := Contender_Better;
                     elsif Direction (Axis) = Lower_Is_Better and then Item.Confidence_Low > Threshold then
                        Item.Verdict := Reference_Better;
                     elsif Direction (Axis) = Higher_Is_Better and then Item.Confidence_Low > Threshold then
                        Item.Verdict := Contender_Better;
                     elsif Direction (Axis) = Higher_Is_Better and then Item.Confidence_High < -Threshold then
                        Item.Verdict := Reference_Better;
                     end if;
                  end;
               elsif Item.Confidence_Low = 0.0 and then Item.Confidence_High = 0.0 then
                  Item.Verdict := Metric_Practically_Equivalent;
               elsif Direction (Axis) = Lower_Is_Better and then Item.Confidence_High < 0.0 then
                  Item.Verdict := Contender_Better;
               elsif Direction (Axis) = Lower_Is_Better and then Item.Confidence_Low > 0.0 then
                  Item.Verdict := Reference_Better;
               elsif Direction (Axis) = Higher_Is_Better and then Item.Confidence_Low > 0.0 then
                  Item.Verdict := Contender_Better;
               elsif Direction (Axis) = Higher_Is_Better and then Item.Confidence_High < 0.0 then
                  Item.Verdict := Reference_Better;
               end if;
               Result.Metric_Comparisons (Axis) := Item;
            end;
         end if;
      end loop;
   end Analyze_Metric_Comparisons;

   procedure Analyze_Comparison (Result : in out Comparison) is
      Count                   : constant Positive := Positive (Result.Reference_Data.Sample_Total);
      Ratios                  : Float_Array (1 .. Count);
      Log_Ratios              : Float_Array (1 .. Count);
      Log_Sum                 : Long_Float := 0.0;
      Difference_Sum          : Long_Float := 0.0;
      Reference_First_Log_Sum : Long_Float := 0.0;
      Contender_First_Log_Sum : Long_Float := 0.0;
   begin
      for Index in 1 .. Count loop
         declare
            Reference_Time : constant Long_Float := Result.Reference_Data.Values (Sample_Index (Index));
            Contender_Time : constant Long_Float := Result.Contender_Data.Values (Sample_Index (Index));
            Ratio          : Long_Float;
         begin
            if Reference_Time <= 0.0 or else Contender_Time <= 0.0 then
               raise Program_Error
                 with
                   "comparison produced a zero-duration sample; increase the "
                   & "minimum sample time or disable timer-cost subtraction";
            end if;
            Ratio := Reference_Time / Contender_Time;
            Result.Speedup_Values (Sample_Index (Index)) := Ratio;
            Ratios (Index) := Ratio;
            Log_Ratios (Index) := Math.Log (Ratio);
            Log_Sum := Log_Sum + Log_Ratios (Index);
            if Result.Reference_First_Order (Sample_Index (Index)) then
               Reference_First_Log_Sum := Reference_First_Log_Sum + Log_Ratios (Index);
            else
               Contender_First_Log_Sum := Contender_First_Log_Sum + Log_Ratios (Index);
            end if;
            Difference_Sum := Difference_Sum + Contender_Time - Reference_Time;

            if Contender_Time < Reference_Time then
               Result.Contender_Win_Total := Result.Contender_Win_Total + 1;
            elsif Reference_Time < Contender_Time then
               Result.Reference_Win_Total := Result.Reference_Win_Total + 1;
            else
               Result.Tie_Total := Result.Tie_Total + 1;
            end if;
         end;
      end loop;

      Result.Geometric_Speedup := Math.Exp (Log_Sum / Long_Float (Count));
      Result.Mean_Time_Difference := Difference_Sum / Long_Float (Count);
      Sort (Ratios);
      Result.Median_Speedup_Value := Percentile (Ratios, 0.5);

      if Result.Reference_First > 0 and then Result.Contender_First > 0 then
         Result.Order_Effect :=
           100.0
           * (Math.Exp
                (Reference_First_Log_Sum
                 / Long_Float (Result.Reference_First)
                 - Contender_First_Log_Sum / Long_Float (Result.Contender_First))
              - 1.0);
      end if;

      if Count > 2 then
         declare
            Mean_Log  : constant Long_Float := Log_Sum / Long_Float (Count);
            Numerator : Long_Float := 0.0;
            Left_Sum  : Long_Float := 0.0;
            Right_Sum : Long_Float := 0.0;
         begin
            for Index in 2 .. Count loop
               declare
                  Left  : constant Long_Float := Log_Ratios (Index - 1) - Mean_Log;
                  Right : constant Long_Float := Log_Ratios (Index) - Mean_Log;
               begin
                  Numerator := Numerator + Left * Right;
                  Left_Sum := Left_Sum + Left * Left;
                  Right_Sum := Right_Sum + Right * Right;
               end;
            end loop;
            if Left_Sum > 0.0 and then Right_Sum > 0.0 then
               Result.Lag_One := Numerator / Math.Sqrt (Left_Sum * Right_Sum);
            end if;
         end;
      end if;

      declare
         Bootstrap_Speedups : Float_Array (1 .. Result.Reference_Data.Bootstrap_Resample_Total);
         State              : Interfaces.Unsigned_64 :=
           16#D1B5_4A32_D192_ED03# xor Interfaces.Unsigned_64 (Result.Random_Seed_Value);
         Block_Length       : constant Positive :=
           Positive'Max (2, Positive (Long_Float'Ceiling (Math.Sqrt (Long_Float (Count)))));
      begin
         for Resample in Bootstrap_Speedups'Range loop
            Log_Sum := 0.0;
            declare
               Drawn : Natural := 0;
            begin
               while Drawn < Count loop
                  declare
                     Start : constant Positive :=
                       Positive (Natural (Next_Random (State) mod Interfaces.Unsigned_64 (Count)) + 1);
                  begin
                     for Offset in 0 .. Block_Length - 1 loop
                        exit when Drawn = Count;
                        declare
                           Index : constant Positive := ((Start - 1 + Offset) mod Count) + 1;
                        begin
                           Log_Sum := Log_Sum + Log_Ratios (Index);
                           Drawn := Drawn + 1;
                        end;
                     end loop;
                  end;
               end loop;
            end;
            Bootstrap_Speedups (Resample) := Math.Exp (Log_Sum / Long_Float (Count));
         end loop;
         Sort (Bootstrap_Speedups);
         Result.Speedup_CI_Low :=
           Percentile (Bootstrap_Speedups, Lower_Tail (Result.Reference_Data.Confidence_Level_Value));
         Result.Speedup_CI_High :=
           Percentile (Bootstrap_Speedups, 1.0 - Lower_Tail (Result.Reference_Data.Confidence_Level_Value));
      end;

      declare
         Change_Low  : constant Long_Float := 100.0 * (1.0 / Result.Speedup_CI_High - 1.0);
         Change_High : constant Long_Float := 100.0 * (1.0 / Result.Speedup_CI_Low - 1.0);
         Threshold   : constant Long_Float := Result.Practical_Threshold;
      begin
         if Change_High < -Threshold then
            Result.Verdict_Value := Contender_Faster;
         elsif Change_Low > Threshold then
            Result.Verdict_Value := Reference_Faster;
         elsif Change_Low >= -Threshold and then Change_High <= Threshold then
            Result.Verdict_Value := Practically_Equivalent;
         else
            Result.Verdict_Value := Inconclusive;
         end if;
      end;
      Analyze_Metric_Comparisons (Result);
      Analyze_Custom_Comparisons (Result);
   end Analyze_Comparison;

   function Measurement_Statistics_Consistent (Value : Measurement) return Boolean is
      Expected : Measurement;
   begin
      Expected.Sample_Total := Value.Sample_Total;
      Expected.Values := Value.Values;
      Expected.Random_Seed_Value := Value.Random_Seed_Value;
      Analyze (Expected);

      if Value.Minimum /= Expected.Minimum
        or else Value.Maximum /= Expected.Maximum
        or else Value.Mean /= Expected.Mean
        or else Value.Median /= Expected.Median
        or else Value.Standard_Deviation /= Expected.Standard_Deviation
        or else Value.MAD /= Expected.MAD
        or else Value.P95 /= Expected.P95
        or else Value.P99 /= Expected.P99
        or else Value.Confidence_Low /= Expected.Confidence_Low
        or else Value.Confidence_High /= Expected.Confidence_High
        or else Value.CV_Percent /= Expected.CV_Percent
        or else Value.Outlier_Total /= Expected.Outlier_Total
        or else Value.Lag_One /= Expected.Lag_One
        or else Value.Median_Batch /= Value.Median * Long_Float (Value.Iterations)
      then
         return False;
      end if;

      if Value.Metric_Data.Data /= null then
         Expected.Metric_Data.Data :=
           new Metric_Store'
             (References => 1,
              Requested  => Value.Metric_Data.Data.Requested,
              Available  => Value.Metric_Data.Data.Available,
              Status     => Value.Metric_Data.Data.Status,
              Values     => Value.Metric_Data.Data.Values,
              Summaries  => [others => (others => <>)]);
         Analyze_Metrics (Expected);
         for Axis in Metric_Axis loop
            if Value.Metric_Data.Data.Available (Axis)
              and then Value.Metric_Data.Data.Summaries (Axis) /= Expected.Metric_Data.Data.Summaries (Axis)
            then
               return False;
            end if;
         end loop;
      end if;
      return True;
   exception
      when others =>
         return False;
   end Measurement_Statistics_Consistent;

   function Comparison_Statistics_Consistent (Value : Comparison) return Boolean is
      Expected : Comparison;
   begin
      Expected.Reference_Data := Value.Reference_Data;
      Expected.Contender_Data := Value.Contender_Data;
      Expected.Reference_First_Order := Value.Reference_First_Order;
      Expected.Reference_First := Value.Reference_First;
      Expected.Contender_First := Value.Contender_First;
      Expected.Practical_Threshold := Value.Practical_Threshold;
      Expected.Random_Seed_Value := Value.Random_Seed_Value;
      Analyze_Comparison (Expected);
      return
        Value.Speedup_Values = Expected.Speedup_Values
        and then Value.Geometric_Speedup = Expected.Geometric_Speedup
        and then Value.Median_Speedup_Value = Expected.Median_Speedup_Value
        and then Value.Speedup_CI_Low = Expected.Speedup_CI_Low
        and then Value.Speedup_CI_High = Expected.Speedup_CI_High
        and then Value.Mean_Time_Difference = Expected.Mean_Time_Difference
        and then Value.Contender_Win_Total = Expected.Contender_Win_Total
        and then Value.Reference_Win_Total = Expected.Reference_Win_Total
        and then Value.Tie_Total = Expected.Tie_Total
        and then Value.Order_Effect = Expected.Order_Effect
        and then Value.Lag_One = Expected.Lag_One
        and then Value.Verdict_Value = Expected.Verdict_Value
        and then Value.Metric_Comparisons = Expected.Metric_Comparisons;
   exception
      when others =>
         return False;
   end Comparison_Statistics_Consistent;

   generic
      with procedure Run_Batch (Iterations : Iteration_Count);
      with procedure Prepare_Batch;
      with procedure Finish_Batch;
   procedure Measure_Core (Config : Configuration; Result : out Measurement);

   procedure Measure_Core (Config : Configuration; Result : out Measurement) is
      Batch_Iterations            : Iteration_Count := 1;
      Calibration_Base_Iterations : Iteration_Count := 1;
      Target_NS                   : Long_Float;
      Clock_Cost                  : Long_Float;
      Calibration_Hits            : Natural := 0;
      Recalibrate                 : Boolean;
      Perf                        : Counters.Handle;
      Watch                       : Interference_Watch;
      Lock                        : Host_Lock.Claim;

      function Time_Batch (Iterations : Iteration_Count) return Long_Float is
         Started  : Interfaces.Unsigned_64;
         Finished : Interfaces.Unsigned_64;
      begin
         Prepare_Batch;
         Internal_Probes.Clobber_Memory;
         Started := Clock_Now;
         begin
            Run_Batch (Iterations);
         exception
            when others =>
               Finished := Clock_Now;
               Internal_Probes.Clobber_Memory;
               Finish_Batch;
               raise;
         end;
         Finished := Clock_Now;
         Internal_Probes.Clobber_Memory;
         Finish_Batch;
         return Elapsed_Nanoseconds (Started, Finished);
      end Time_Batch;

      function Time_Sampled_Batch (Index : Sample_Index) return Long_Float is
         Probe    : Sample_Probe_State;
         Started  : Interfaces.Unsigned_64;
         Finished : Interfaces.Unsigned_64;
         Elapsed  : Long_Float;
      begin
         Prepare_Batch;
         begin
            Start_Sample (Config, Perf, Probe);
            Internal_Probes.Clobber_Memory;
            Started := Clock_Now;
            Run_Batch (Batch_Iterations);
            Finished := Clock_Now;
            Internal_Probes.Clobber_Memory;
            Elapsed := Elapsed_Nanoseconds (Started, Finished);
            Finish_Sample (Config, Perf, Probe, Result, Index, Batch_Iterations, Elapsed);
         exception
            when others =>
               Internal_Probes.Clobber_Memory;
               Finish_Batch;
               raise;
         end;
         Finish_Batch;
         return Elapsed;
      end Time_Sampled_Batch;

      procedure Increase_Batch (Elapsed : Long_Float) is
         Scale     : Long_Float;
         Candidate : Iteration_Count;
      begin
         if Batch_Iterations = Config.Maximum_Iterations then
            return;
         elsif Elapsed <= 0.0 then
            Scale := 2.0;
         else
            Scale := Long_Float'Max (2.0, Target_NS / Elapsed);
            Scale := Long_Float'Min (Scale, 2.0);
         end if;

         if Scale >= Long_Float (Config.Maximum_Iterations) / Long_Float (Batch_Iterations) then
            Candidate := Config.Maximum_Iterations;
         else
            Candidate := Iteration_Count (Long_Float'Floor (Long_Float (Batch_Iterations) * Scale));
            Candidate := Iteration_Count'Max (Candidate, Batch_Iterations + 1);
            Candidate := Iteration_Count'Min (Candidate, Config.Maximum_Iterations);
         end if;
         Batch_Iterations := Candidate;
      end Increase_Batch;

   begin
      Validate_Bootstrap_Work (Config, 1, "measurement");
      Result := (others => <>);
      Result.Sample_Total := Config.Samples;
      Result.Confidence_Level_Value := Config.Confidence_Level_Percent;
      Result.Bootstrap_Resample_Total := Config.Bootstrap_Resamples;
      Result.Random_Seed_Value := Config.Random_Seed;
      Initialize_Metrics (Config, Result);
      Notify (Config, Starting);
      Prepare_Environment (Config, Watch, Lock);
      Prepare_Operating_Conditions (Config, Watch);
      Await_CPU_Quiescence (Config);
      Characterize_Clock
        (Backend             => Result.Clock_Backend_Id,
         Nominal_Resolution  => Result.Clock_Resolution,
         Observed_Resolution => Result.Observed_Resolution,
         Minimum_Cost        => Clock_Cost,
         Median_Cost         => Result.Median_Timer_Cost);
      Result.Timer_Cost := Clock_Cost;
      Target_NS :=
        Long_Float'Max
          (Long_Float (Config.Minimum_Sample_Time) * 1_000_000_000.0,
           Long_Float (Config.Measurement_Time) * 1_000_000_000.0 / Long_Float (Config.Samples));

      if Config.Warmup_Time > 0.0 then
         declare
            Started  : constant Interfaces.Unsigned_64 := Clock_Now;
            Span     : constant Interfaces.Unsigned_64 := Duration_Nanoseconds (Config.Warmup_Time);
            Deadline : constant Interfaces.Unsigned_64 := Started + Span;
            Elapsed  : Long_Float;
            Current  : Interfaces.Unsigned_64;
         begin
            Notify (Config, Warming, 0, 100);
            loop
               Elapsed := Time_Batch (Batch_Iterations);
               if Elapsed < Target_NS * 0.5 and then Batch_Iterations < Config.Maximum_Iterations then
                  Increase_Batch (Elapsed);
               end if;
               Current := Clock_Now;
               Notify
                 (Config,
                  Warming,
                  Natural'Min
                    (100,
                     Natural (Long_Float'Floor (100.0 * Long_Float (Current - Started) / Long_Float (Span)))),
                  100);
               exit when Current >= Deadline;
            end loop;
         end;
      end if;

      Establish_Operating_Baseline (Config, Watch);
      Calibration_Base_Iterations := Batch_Iterations;
      loop
         Batch_Iterations := Calibration_Base_Iterations;
         Calibration_Hits := 0;
         Open_Condition_Window (Watch);
         Notify (Config, Calibrating);
         loop
            declare
               Elapsed : constant Long_Float := Time_Batch (Batch_Iterations);
            begin
               if Elapsed >= Target_NS * 0.9 then
                  Calibration_Hits := Calibration_Hits + 1;
               else
                  Calibration_Hits := 0;
                  Increase_Batch (Elapsed);
               end if;
               exit when Calibration_Hits >= 3 or else Batch_Iterations = Config.Maximum_Iterations;
            end;
         end loop;
         Validate_After_Calibration (Config, Watch, Recalibrate);
         exit when not Recalibrate;
      end loop;

      Result.Iterations := Batch_Iterations;
      Initialize_Perf (Config, Perf);
      declare
         Sampling_Started         : constant Interfaces.Unsigned_64 := Clock_Now;
         Paused_At_Sampling_Start : constant Interfaces.Unsigned_64 := Watch.Paused_Total;
         Completed                : Natural := 0;
         Total_Samples            : constant Positive := Natural (Config.Samples);
         Group                    : constant Positive := Units_Per_Window (Config, Target_NS, Total_Samples);
         Window_First             : Positive := 1;
         Window_Last              : Positive;
         Action                   : Window_Action;
         Condition_Result         : Condition_Action;
         Recovered                : Boolean;
         Terminal_Window          : Boolean;

         --  A resumed run has cold caches, predictors, and frequency state.
         --  Without this the first sample after a pause is exactly the
         --  outlier the pause was meant to avoid.
         procedure Rewarm (Span : Nonnegative_Duration) is
            Deadline : Interfaces.Unsigned_64;
            Elapsed  : Long_Float;
            Started  : Interfaces.Unsigned_64;
         begin
            if Span <= 0.0 then
               return;
            end if;
            Started := Clock_Now;
            Deadline := Started + Duration_Nanoseconds (Span);
            Notify (Config, Warming, 0, 100);
            loop
               Elapsed := Time_Batch (Batch_Iterations);
               Internal_Probes.Escape (Elapsed'Address);
               exit when Clock_Now >= Deadline;
            end loop;
            Watch.Paused_Total := Watch.Paused_Total + (Clock_Now - Started);
            Notify (Config, Warming, 100, 100);
         end Rewarm;
      begin
         Notify (Config, Sampling, 0, Natural (Config.Samples));
         while Window_First <= Total_Samples loop
            Window_Last := Positive'Min (Window_First + Group - 1, Total_Samples);
            loop
               declare
                  Saved : constant Telemetry_Snapshot := Save_Telemetry (Result);
               begin
                  Open_Interference_Window (Watch);
                  Open_Condition_Window (Watch);
                  for Index in Window_First .. Window_Last loop
                     declare
                        Elapsed : Long_Float;
                     begin
                        Elapsed := Time_Sampled_Batch (Sample_Index (Index));
                        if Config.Subtract_Timer_Cost and then Elapsed > Clock_Cost then
                           Elapsed := Elapsed - Clock_Cost;
                        end if;
                        Result.Values (Sample_Index (Index)) := Elapsed / Long_Float (Batch_Iterations);
                     end;
                     Completed := Natural'Max (Completed, Index);
                     Notify (Config, Sampling, Completed, Natural (Config.Samples));
                  end loop;
                  Judge_Window
                    (Config, Watch, Sample_Index (Window_First), Sample_Index (Window_Last), Action);
                  Terminal_Window :=
                    Window_Last = Total_Samples
                    or else Sampling_Limit_Reached
                              (Config,
                               Sampling_Started,
                               Completed,
                               Watch.Paused_Total - Paused_At_Sampling_Start);
                  Judge_Condition_Window
                    (Config,
                     Watch,
                     Window_Last - Window_First + 1,
                     Condition_Result,
                     Force_Profile => Terminal_Window);
                  if Condition_Result = Fail_Conditions then
                     raise Operating_Conditions_Unacceptable
                       with "operating conditions changed during measurement";
                  elsif Condition_Result = Pause_For_Conditions then
                     Await_Condition_Settle (Config, Watch, Recovered);
                     if Recovered then
                        Watch.Report.Recollected_Units :=
                          Watch.Report.Recollected_Units + Window_Last - Window_First + 1;
                        Restore_Telemetry (Result, Saved);
                        if Action = Settle_And_Retake then
                           Await_Foreign_Settle (Config, Watch);
                           Rewarm
                             (Duration'Max
                                (Config.Operating_Conditions.Rewarm_Time, Config.Interference.Rewarm_Time));
                        else
                           Rewarm (Config.Operating_Conditions.Rewarm_Time);
                        end if;
                     elsif Action = Accept_Window then
                        exit;
                     else
                        Restore_Telemetry (Result, Saved);
                        if Action = Settle_And_Retake then
                           Await_Foreign_Settle (Config, Watch);
                           Rewarm (Config.Interference.Rewarm_Time);
                        end if;
                     end if;
                  elsif Action = Accept_Window then
                     exit;
                  else
                     Restore_Telemetry (Result, Saved);
                     if Action = Settle_And_Retake then
                        Await_Foreign_Settle (Config, Watch);
                        Rewarm (Config.Interference.Rewarm_Time);
                     end if;
                  end if;
               end;
            end loop;
            exit when Terminal_Window;
            Window_First := Window_Last + 1;
         end loop;
         Result.Sample_Total := Sample_Count (Completed);
      end;
      Finalize_Operating_Conditions (Watch);
      Apply_Environment (Watch, Result);
      Notify (Config, Analyzing);
      Analyze (Result);
      Analyze_Metrics (Result);
      Analyze_Custom_Metrics (Result);
      Result.Median_Batch := Result.Median * Long_Float (Result.Iterations);
      Notify (Config, Finished, 1, 1);
   end Measure_Core;

   generic
      with procedure Run_Reference_Batch (Iterations : Iteration_Count);
      with procedure Run_Contender_Batch (Iterations : Iteration_Count);
   procedure Compare_Core (Config : Configuration; Result : out Comparison);

   procedure Compare_Core (Config : Configuration; Result : out Comparison) is
      type Order_Array is array (Positive range <>) of Boolean;

      Batch_Iterations           : Iteration_Count := 1;
      Reference_Iterations       : Iteration_Count := 1;
      Contender_Iterations       : Iteration_Count := 1;
      Calibration_Base_Batch     : Iteration_Count := 1;
      Calibration_Base_Reference : Iteration_Count := 1;
      Calibration_Base_Contender : Iteration_Count := 1;
      Target_NS                  : Long_Float;
      Clock_Cost                 : Long_Float;
      Calibration_Hits           : Natural := 0;
      Slow_Limit_Hits            : Natural := 0;
      Recalibrate                : Boolean;
      Perf                       : Counters.Handle;
      Watch                      : Interference_Watch;
      Lock                       : Host_Lock.Claim;
      Warmup_State               : Interfaces.Unsigned_64 :=
        16#A076_1D64_78BD_642F# xor Interfaces.Unsigned_64 (Config.Random_Seed);

      function Reference_Count return Iteration_Count
      is (if Config.Comparison_Batching = Equal_Time then Reference_Iterations else Batch_Iterations);

      function Contender_Count return Iteration_Count
      is (if Config.Comparison_Batching = Equal_Time then Contender_Iterations else Batch_Iterations);

      function Time_Reference (Iterations : Iteration_Count) return Long_Float is
         Started  : Interfaces.Unsigned_64;
         Finished : Interfaces.Unsigned_64;
      begin
         Internal_Probes.Clobber_Memory;
         Started := Clock_Now;
         Run_Reference_Batch (Iterations);
         Finished := Clock_Now;
         Internal_Probes.Clobber_Memory;
         return Elapsed_Nanoseconds (Started, Finished);
      end Time_Reference;

      function Time_Contender (Iterations : Iteration_Count) return Long_Float is
         Started  : Interfaces.Unsigned_64;
         Finished : Interfaces.Unsigned_64;
      begin
         Internal_Probes.Clobber_Memory;
         Started := Clock_Now;
         Run_Contender_Batch (Iterations);
         Finished := Clock_Now;
         Internal_Probes.Clobber_Memory;
         return Elapsed_Nanoseconds (Started, Finished);
      end Time_Contender;

      procedure Time_Pair
        (Reference_First : Boolean; Reference_Time : out Long_Float; Contender_Time : out Long_Float) is
      begin
         if Reference_First then
            Reference_Time := Time_Reference (Reference_Count);
            Contender_Time := Time_Contender (Contender_Count);
         else
            Contender_Time := Time_Contender (Contender_Count);
            Reference_Time := Time_Reference (Reference_Count);
         end if;
      end Time_Pair;

      procedure Increase_Individual_Batch (Iterations : in out Iteration_Count; Elapsed : Long_Float) is
         Scale     : Long_Float;
         Candidate : Iteration_Count;
      begin
         if Iterations = Config.Maximum_Iterations then
            return;
         elsif Elapsed <= 0.0 then
            Scale := 2.0;
         else
            Scale := Long_Float'Max (1.25, Target_NS / Elapsed);
            Scale := Long_Float'Min (Scale, 2.0);
         end if;
         if Scale >= Long_Float (Config.Maximum_Iterations) / Long_Float (Iterations) then
            Candidate := Config.Maximum_Iterations;
         else
            Candidate := Iteration_Count (Long_Float'Floor (Long_Float (Iterations) * Scale));
            Candidate := Iteration_Count'Max (Candidate, Iterations + 1);
            Candidate := Iteration_Count'Min (Candidate, Config.Maximum_Iterations);
         end if;
         Iterations := Candidate;
      end Increase_Individual_Batch;

      procedure Increase_Batch (Fastest : Long_Float; Slowest : Long_Float) is
         Scale     : Long_Float;
         Candidate : Iteration_Count;
      begin
         if Batch_Iterations = Config.Maximum_Iterations or else Slowest >= Target_NS * 8.0 then
            return;
         elsif Fastest <= 0.0 then
            Scale := 2.0;
         else
            Scale := Long_Float'Max (2.0, Target_NS / Fastest);
            Scale := Long_Float'Min (Scale, 2.0);
         end if;

         if Scale >= Long_Float (Config.Maximum_Iterations) / Long_Float (Batch_Iterations) then
            Candidate := Config.Maximum_Iterations;
         else
            Candidate := Iteration_Count (Long_Float'Floor (Long_Float (Batch_Iterations) * Scale));
            Candidate := Iteration_Count'Max (Candidate, Batch_Iterations + 1);
            Candidate := Iteration_Count'Min (Candidate, Config.Maximum_Iterations);
         end if;
         Batch_Iterations := Candidate;
      end Increase_Batch;

      procedure Adjust_Timer_Cost (Elapsed : in out Long_Float) is
      begin
         if Config.Subtract_Timer_Cost and then Elapsed > Clock_Cost then
            Elapsed := Elapsed - Clock_Cost;
         end if;
      end Adjust_Timer_Cost;

   begin
      Validate_Bootstrap_Work (Config, 3, "paired comparison");
      Result := (others => <>);
      Notify (Config, Starting);
      Prepare_Environment (Config, Watch, Lock);
      Prepare_Operating_Conditions (Config, Watch);
      Await_CPU_Quiescence (Config);
      Result.Reference_Data.Sample_Total := Config.Samples;
      Result.Contender_Data.Sample_Total := Config.Samples;
      Result.Reference_Data.Confidence_Level_Value := Config.Confidence_Level_Percent;
      Result.Contender_Data.Confidence_Level_Value := Config.Confidence_Level_Percent;
      Result.Reference_Data.Bootstrap_Resample_Total := Config.Bootstrap_Resamples;
      Result.Contender_Data.Bootstrap_Resample_Total := Config.Bootstrap_Resamples;
      Result.Reference_Data.Random_Seed_Value := Config.Random_Seed;
      Result.Contender_Data.Random_Seed_Value := Config.Random_Seed;
      Initialize_Metrics (Config, Result.Reference_Data);
      Initialize_Metrics (Config, Result.Contender_Data);
      Characterize_Clock
        (Backend             => Result.Reference_Data.Clock_Backend_Id,
         Nominal_Resolution  => Result.Reference_Data.Clock_Resolution,
         Observed_Resolution => Result.Reference_Data.Observed_Resolution,
         Minimum_Cost        => Clock_Cost,
         Median_Cost         => Result.Reference_Data.Median_Timer_Cost);
      Result.Contender_Data.Clock_Backend_Id := Result.Reference_Data.Clock_Backend_Id;
      Result.Contender_Data.Clock_Resolution := Result.Reference_Data.Clock_Resolution;
      Result.Contender_Data.Observed_Resolution := Result.Reference_Data.Observed_Resolution;
      Result.Contender_Data.Median_Timer_Cost := Result.Reference_Data.Median_Timer_Cost;
      Result.Reference_Data.Timer_Cost := Clock_Cost;
      Result.Contender_Data.Timer_Cost := Clock_Cost;
      Result.Practical_Threshold := Config.Practical_Threshold_Percent;
      Result.Random_Seed_Value := Config.Random_Seed;
      Target_NS :=
        Long_Float'Max
          (Long_Float (Config.Minimum_Sample_Time) * 1_000_000_000.0,
           Long_Float (Config.Measurement_Time) * 1_000_000_000.0 / (2.0 * Long_Float (Config.Samples)));

      if Config.Warmup_Time > 0.0 then
         declare
            Started        : constant Interfaces.Unsigned_64 := Clock_Now;
            Span           : constant Interfaces.Unsigned_64 := Duration_Nanoseconds (Config.Warmup_Time);
            Deadline       : constant Interfaces.Unsigned_64 := Started + Span;
            Reference_Time : Long_Float;
            Contender_Time : Long_Float;
            Current        : Interfaces.Unsigned_64;
         begin
            Notify (Config, Warming, 0, 100);
            loop
               Time_Pair
                 (Reference_First => Next_Random (Warmup_State) mod 2 = 0,
                  Reference_Time  => Reference_Time,
                  Contender_Time  => Contender_Time);
               if Config.Comparison_Batching = Equal_Time then
                  if Reference_Time < Target_NS * 0.5 then
                     Increase_Individual_Batch (Reference_Iterations, Reference_Time);
                  end if;
                  if Contender_Time < Target_NS * 0.5 then
                     Increase_Individual_Batch (Contender_Iterations, Contender_Time);
                  end if;
               elsif Long_Float'Min (Reference_Time, Contender_Time) < Target_NS * 0.5
                 and then Long_Float'Max (Reference_Time, Contender_Time) < Target_NS * 8.0
                 and then Batch_Iterations < Config.Maximum_Iterations
               then
                  Increase_Batch
                    (Fastest => Long_Float'Min (Reference_Time, Contender_Time),
                     Slowest => Long_Float'Max (Reference_Time, Contender_Time));
               end if;
               Current := Clock_Now;
               Notify
                 (Config,
                  Warming,
                  Natural'Min
                    (100,
                     Natural (Long_Float'Floor (100.0 * Long_Float (Current - Started) / Long_Float (Span)))),
                  100);
               exit when Current >= Deadline;
            end loop;
         end;
      end if;

      Establish_Operating_Baseline (Config, Watch);
      Calibration_Base_Batch := Batch_Iterations;
      Calibration_Base_Reference := Reference_Iterations;
      Calibration_Base_Contender := Contender_Iterations;
      loop
         Batch_Iterations := Calibration_Base_Batch;
         Reference_Iterations := Calibration_Base_Reference;
         Contender_Iterations := Calibration_Base_Contender;
         Calibration_Hits := 0;
         Slow_Limit_Hits := 0;
         Open_Condition_Window (Watch);
         Notify (Config, Calibrating);
         loop
            declare
               Reference_Time : Long_Float;
               Contender_Time : Long_Float;
            begin
               Time_Pair
                 (Reference_First => Next_Random (Warmup_State) mod 2 = 0,
                  Reference_Time  => Reference_Time,
                  Contender_Time  => Contender_Time);
               if Config.Comparison_Batching = Equal_Time then
                  if (Reference_Time >= Target_NS * 0.9
                      or else Reference_Iterations = Config.Maximum_Iterations)
                    and then (Contender_Time >= Target_NS * 0.9
                              or else Contender_Iterations = Config.Maximum_Iterations)
                  then
                     Calibration_Hits := Calibration_Hits + 1;
                  else
                     Calibration_Hits := 0;
                  end if;
                  exit when Calibration_Hits >= 3;
                  if Reference_Time < Target_NS * 0.9 then
                     Increase_Individual_Batch (Reference_Iterations, Reference_Time);
                  end if;
                  if Contender_Time < Target_NS * 0.9 then
                     Increase_Individual_Batch (Contender_Iterations, Contender_Time);
                  end if;
               else
                  if Long_Float'Min (Reference_Time, Contender_Time) >= Target_NS * 0.9 then
                     Calibration_Hits := Calibration_Hits + 1;
                  else
                     Calibration_Hits := 0;
                  end if;
                  if Long_Float'Max (Reference_Time, Contender_Time) >= Target_NS * 8.0 then
                     Slow_Limit_Hits := Slow_Limit_Hits + 1;
                  else
                     Slow_Limit_Hits := 0;
                  end if;
                  exit when
                    Calibration_Hits >= 3
                    or else Slow_Limit_Hits >= 3
                    or else Batch_Iterations = Config.Maximum_Iterations;
                  Increase_Batch
                    (Fastest => Long_Float'Min (Reference_Time, Contender_Time),
                     Slowest => Long_Float'Max (Reference_Time, Contender_Time));
               end if;
            end;
         end loop;
         Validate_After_Calibration (Config, Watch, Recalibrate);
         exit when not Recalibrate;
      end loop;

      Result.Reference_Data.Iterations := Reference_Count;
      Result.Contender_Data.Iterations := Contender_Count;
      Initialize_Perf (Config, Perf);
      declare
         Count  : constant Positive := Positive (Config.Samples);
         Orders : Order_Array (1 .. Count);
         State  : Interfaces.Unsigned_64 :=
           16#E703_7ED1_A0B4_28DB# xor Interfaces.Unsigned_64 (Config.Random_Seed);
      begin
         for Index in Orders'Range loop
            Orders (Index) := Index <= (Count + 1) / 2;
         end loop;
         for Index in reverse 2 .. Count loop
            declare
               Other : constant Positive :=
                 Positive (Natural (Next_Random (State) mod Interfaces.Unsigned_64 (Index)) + 1);
               Saved : constant Boolean := Orders (Index);
            begin
               Orders (Index) := Orders (Other);
               Orders (Other) := Saved;
            end;
         end loop;

         declare
            Sampling_Started         : constant Interfaces.Unsigned_64 := Clock_Now;
            Paused_At_Sampling_Start : constant Interfaces.Unsigned_64 := Watch.Paused_Total;
            Completed                : Natural := 0;
            Total_Samples            : constant Positive := Orders'Length;
            --  One unit is a complete pair, so a window never splits the two
            --  halves that make the comparison paired.
            Group                    : constant Positive :=
              Units_Per_Window (Config, 2.0 * Target_NS, Total_Samples);
            Window_First             : Positive := 1;
            Window_Last              : Positive;
            Action                   : Window_Action;
            Condition_Result         : Condition_Action;
            Recovered                : Boolean;
            Terminal_Window          : Boolean;

            procedure Collect_Pair (Index : Positive) is
               Reference_Time  : Long_Float;
               Contender_Time  : Long_Float;
               Reference_Probe : Sample_Probe_State;
               Contender_Probe : Sample_Probe_State;
            begin
               if Orders (Index) then
                  Start_Sample (Config, Perf, Reference_Probe);
                  Reference_Time := Time_Reference (Reference_Count);
                  Finish_Sample
                    (Config,
                     Perf,
                     Reference_Probe,
                     Result.Reference_Data,
                     Sample_Index (Index),
                     Reference_Count,
                     Reference_Time);
                  Start_Sample (Config, Perf, Contender_Probe);
                  Contender_Time := Time_Contender (Contender_Count);
                  Finish_Sample
                    (Config,
                     Perf,
                     Contender_Probe,
                     Result.Contender_Data,
                     Sample_Index (Index),
                     Contender_Count,
                     Contender_Time);
               else
                  Start_Sample (Config, Perf, Contender_Probe);
                  Contender_Time := Time_Contender (Contender_Count);
                  Finish_Sample
                    (Config,
                     Perf,
                     Contender_Probe,
                     Result.Contender_Data,
                     Sample_Index (Index),
                     Contender_Count,
                     Contender_Time);
                  Start_Sample (Config, Perf, Reference_Probe);
                  Reference_Time := Time_Reference (Reference_Count);
                  Finish_Sample
                    (Config,
                     Perf,
                     Reference_Probe,
                     Result.Reference_Data,
                     Sample_Index (Index),
                     Reference_Count,
                     Reference_Time);
               end if;
               Adjust_Timer_Cost (Reference_Time);
               Adjust_Timer_Cost (Contender_Time);
               Result.Reference_Data.Values (Sample_Index (Index)) :=
                 Reference_Time / Long_Float (Reference_Count);
               Result.Contender_Data.Values (Sample_Index (Index)) :=
                 Contender_Time / Long_Float (Contender_Count);
               Result.Reference_First_Order (Sample_Index (Index)) := Orders (Index);
               if Orders (Index) then
                  Result.Reference_First := Result.Reference_First + 1;
               else
                  Result.Contender_First := Result.Contender_First + 1;
               end if;
            end Collect_Pair;

            procedure Rewarm (Span : Nonnegative_Duration) is
               Deadline       : Interfaces.Unsigned_64;
               Reference_Time : Long_Float;
               Contender_Time : Long_Float;
               Started        : Interfaces.Unsigned_64;
            begin
               if Span <= 0.0 then
                  return;
               end if;
               Started := Clock_Now;
               Deadline := Started + Duration_Nanoseconds (Span);
               Notify (Config, Warming, 0, 100);
               loop
                  Time_Pair
                    (Reference_First => True,
                     Reference_Time  => Reference_Time,
                     Contender_Time  => Contender_Time);
                  Internal_Probes.Escape (Reference_Time'Address);
                  Internal_Probes.Escape (Contender_Time'Address);
                  exit when Clock_Now >= Deadline;
               end loop;
               Watch.Paused_Total := Watch.Paused_Total + (Clock_Now - Started);
               Notify (Config, Warming, 100, 100);
            end Rewarm;

            procedure Roll_Back_Window
              (Saved_Reference : Telemetry_Snapshot; Saved_Contender : Telemetry_Snapshot) is
            begin
               for Index in Window_First .. Window_Last loop
                  if Orders (Index) then
                     Result.Reference_First := Result.Reference_First - 1;
                  else
                     Result.Contender_First := Result.Contender_First - 1;
                  end if;
               end loop;
               Restore_Telemetry (Result.Reference_Data, Saved_Reference);
               Restore_Telemetry (Result.Contender_Data, Saved_Contender);
            end Roll_Back_Window;
         begin
            Notify (Config, Sampling, 0, Natural (Config.Samples));
            while Window_First <= Total_Samples loop
               Window_Last := Positive'Min (Window_First + Group - 1, Total_Samples);
               loop
                  declare
                     Saved_Reference : constant Telemetry_Snapshot := Save_Telemetry (Result.Reference_Data);
                     Saved_Contender : constant Telemetry_Snapshot := Save_Telemetry (Result.Contender_Data);
                  begin
                     Open_Interference_Window (Watch);
                     Open_Condition_Window (Watch);
                     for Index in Window_First .. Window_Last loop
                        Collect_Pair (Index);
                        Completed := Natural'Max (Completed, Index);
                        Notify (Config, Sampling, Completed, Natural (Config.Samples));
                     end loop;
                     Judge_Window
                       (Config, Watch, Sample_Index (Window_First), Sample_Index (Window_Last), Action);
                     Terminal_Window :=
                       Window_Last = Total_Samples
                       or else Sampling_Limit_Reached
                                 (Config,
                                  Sampling_Started,
                                  Completed,
                                  Watch.Paused_Total - Paused_At_Sampling_Start);
                     Judge_Condition_Window
                       (Config,
                        Watch,
                        Window_Last - Window_First + 1,
                        Condition_Result,
                        Force_Profile => Terminal_Window);
                     if Condition_Result = Fail_Conditions then
                        raise Operating_Conditions_Unacceptable
                          with "operating conditions changed during paired comparison";
                     elsif Condition_Result = Pause_For_Conditions then
                        Await_Condition_Settle (Config, Watch, Recovered);
                        if Recovered then
                           Watch.Report.Recollected_Units :=
                             Watch.Report.Recollected_Units + Window_Last - Window_First + 1;
                           Roll_Back_Window (Saved_Reference, Saved_Contender);
                           if Action = Settle_And_Retake then
                              Await_Foreign_Settle (Config, Watch);
                              Rewarm
                                (Duration'Max
                                   (Config.Operating_Conditions.Rewarm_Time,
                                    Config.Interference.Rewarm_Time));
                           else
                              Rewarm (Config.Operating_Conditions.Rewarm_Time);
                           end if;
                        elsif Action = Accept_Window then
                           exit;
                        else
                           Roll_Back_Window (Saved_Reference, Saved_Contender);
                           if Action = Settle_And_Retake then
                              Await_Foreign_Settle (Config, Watch);
                              Rewarm (Config.Interference.Rewarm_Time);
                           end if;
                        end if;
                     elsif Action = Accept_Window then
                        exit;
                     else
                        Roll_Back_Window (Saved_Reference, Saved_Contender);
                        if Action = Settle_And_Retake then
                           Await_Foreign_Settle (Config, Watch);
                           Rewarm (Config.Interference.Rewarm_Time);
                        end if;
                     end if;
                  end;
               end loop;
               exit when Terminal_Window;
               Window_First := Window_Last + 1;
            end loop;
            Result.Reference_Data.Sample_Total := Sample_Count (Completed);
            Result.Contender_Data.Sample_Total := Sample_Count (Completed);
         end;
      end;
      Finalize_Operating_Conditions (Watch);
      Apply_Environment (Watch, Result.Reference_Data);
      Apply_Environment (Watch, Result.Contender_Data);

      Notify (Config, Analyzing);
      Analyze (Result.Reference_Data);
      Analyze (Result.Contender_Data);
      Analyze_Metrics (Result.Reference_Data);
      Analyze_Metrics (Result.Contender_Data);
      Analyze_Custom_Metrics (Result.Reference_Data);
      Analyze_Custom_Metrics (Result.Contender_Data);
      Result.Reference_Data.Median_Batch := Result.Reference_Data.Median * Long_Float (Reference_Count);
      Result.Contender_Data.Median_Batch := Result.Contender_Data.Median * Long_Float (Contender_Count);
      Analyze_Comparison (Result);
      Notify (Config, Finished, 1, 1);
   end Compare_Core;

   procedure Measure (Config : Configuration := Default_Configuration; Result : out Measurement) is
      procedure Run_Batch (Iterations : Iteration_Count) is
      begin
         for Iteration in Iteration_Count range 1 .. Iterations loop
            Operation;
         end loop;
      end Run_Batch;

      procedure Nothing is null;

      procedure Run is new Measure_Core (Run_Batch, Nothing, Nothing);
   begin
      Run (Config, Result);
   end Measure;

   procedure Measure_Batched (Config : Configuration := Default_Configuration; Result : out Measurement) is
      procedure Nothing is null;
      procedure Run is new Measure_Core (Batch, Nothing, Nothing);
   begin
      Run (Config, Result);
   end Measure_Batched;

   procedure Measure_With_Hooks (Config : Configuration := Default_Configuration; Result : out Measurement) is
      procedure Run_Batch (Iterations : Iteration_Count) is
      begin
         for Iteration in Iteration_Count range 1 .. Iterations loop
            Operation;
         end loop;
      end Run_Batch;

      procedure Run is new Measure_Core (Run_Batch, Setup, Teardown);
   begin
      Run (Config, Result);
   end Measure_With_Hooks;

   procedure Measure_Result_Batched
     (Config : Configuration := Default_Configuration; Result : out Measurement)
   is
      Latest : aliased Element;

      procedure Run_Batch (Iterations : Iteration_Count) is
      begin
         Batch (Iterations, Latest);
      end Run_Batch;

      procedure Nothing is null;

      procedure Observe is
      begin
         Internal_Probes.Escape (Latest'Address);
      end Observe;

      procedure Run is new Measure_Core (Run_Batch, Nothing, Observe);
   begin
      Run (Config, Result);
   end Measure_Result_Batched;

   procedure Compare (Config : Configuration := Default_Configuration; Result : out Comparison) is
      procedure Run_Reference_Batch (Iterations : Iteration_Count) is
      begin
         for Iteration in Iteration_Count range 1 .. Iterations loop
            Reference_Operation;
         end loop;
      end Run_Reference_Batch;

      procedure Run_Contender_Batch (Iterations : Iteration_Count) is
      begin
         for Iteration in Iteration_Count range 1 .. Iterations loop
            Contender_Operation;
         end loop;
      end Run_Contender_Batch;

      procedure Run is new Compare_Core (Run_Reference_Batch, Run_Contender_Batch);
   begin
      Run (Config, Result);
   end Compare;

   procedure Compare_Batched (Config : Configuration := Default_Configuration; Result : out Comparison) is
      procedure Run is new Compare_Core (Reference_Batch, Contender_Batch);
   begin
      Run (Config, Result);
   end Compare_Batched;

   procedure Compare_Many (Config : Configuration := Default_Configuration; Result : out Multi_Comparison) is
      Count : constant Positive := Case_Id'Pos (Case_Id'Last) + 1;
      type Order_Array is array (Positive range <>) of Positive;
      type Position_Array is array (Positive range <>) of Positive;
      type Schedule_Array is array (Comparison_Case_Index, Sample_Index) of Boolean;
      type Case_Iteration_Array is array (Comparison_Case_Index) of Iteration_Count;
      type Case_Time_Array is array (Comparison_Case_Index) of Long_Float;

      Watch : Interference_Watch;
      Lock  : Host_Lock.Claim;

      Batch_Iterations         : Iteration_Count := 1;
      Case_Iterations          : Case_Iteration_Array := [others => 1];
      Calibration_Base_Batch   : Iteration_Count := 1;
      Calibration_Base_Cases   : Case_Iteration_Array := [others => 1];
      Target_NS                : Long_Float;
      Case_Target_NS           : Long_Float;
      Minimum_Case_NS          : Long_Float;
      Clock_Cost               : Long_Float;
      Calibration_Hits         : Natural := 0;
      Recalibrate              : Boolean;
      State                    : Interfaces.Unsigned_64 :=
        16#E703_7ED1_A0B4_28DB# xor Interfaces.Unsigned_64 (Config.Random_Seed);
      Collected_Samples        : Natural := 0;
      Reference_First_Schedule : Schedule_Array := [others => [others => False]];
      Perf                     : Counters.Handle;

      function Iterations_For (Index : Comparison_Case_Index) return Iteration_Count
      is (if Config.Comparison_Batching = Equal_Time then Case_Iterations (Index) else Batch_Iterations);

      function Progress_Case_Name (Which : Case_Id) return String is
         Result : String := Ada.Characters.Handling.To_Lower (Case_Id'Image (Which));
      begin
         for Character of Result loop
            if Character = '_' then
               Character := ' ';
            end if;
         end loop;
         return Result;
      end Progress_Case_Name;

      procedure Notify_Case (Which : Case_Id; Phase : Progress_Phase; Completed : Natural; Total : Natural) is
         Base_Name : constant String := Ada.Strings.Unbounded.To_String (Config.Progress_Name);
         Case_Name : constant String := Progress_Case_Name (Which);
      begin
         if Config.Progress /= null then
            Config.Progress.all
              ((if Base_Name'Length = 0 then Case_Name else Base_Name & " / " & Case_Name),
               Phase,
               Completed,
               Total);
         end if;
      end Notify_Case;

      function Time_One (Which : Case_Id; Iterations : Iteration_Count) return Long_Float is
         Started  : Interfaces.Unsigned_64;
         Finished : Interfaces.Unsigned_64;
      begin
         Internal_Probes.Clobber_Memory;
         Started := Clock_Now;
         Batch (Which, Iterations);
         Finished := Clock_Now;
         Internal_Probes.Clobber_Memory;
         return Elapsed_Nanoseconds (Started, Finished);
      end Time_One;

      procedure Time_Round (Fastest : out Long_Float; Total : out Long_Float; Times : out Case_Time_Array) is
      begin
         Fastest := Long_Float'Last;
         Total := 0.0;
         for Index in 1 .. Count loop
            declare
               Case_Index : constant Comparison_Case_Index := Comparison_Case_Index (Index);
               Elapsed    : constant Long_Float :=
                 Time_One (Case_Id'Val (Index - 1), Iterations_For (Case_Index));
            begin
               Times (Case_Index) := Elapsed;
               Fastest := Long_Float'Min (Fastest, Elapsed);
               Total := Total + Elapsed;
            end;
         end loop;
      end Time_Round;

      procedure Increase_Batch (Fastest : Long_Float; Total : Long_Float) is
         Scale     : Long_Float;
         Candidate : Iteration_Count;
      begin
         if Batch_Iterations = Config.Maximum_Iterations then
            return;
         elsif Fastest <= 0.0 or else Total <= 0.0 then
            Scale := 2.0;
         else
            Scale := Long_Float'Max (1.25, Long_Float'Max (Target_NS / Total, Minimum_Case_NS / Fastest));
            Scale := Long_Float'Min (Scale, 2.0);
         end if;
         if Scale >= Long_Float (Config.Maximum_Iterations) / Long_Float (Batch_Iterations) then
            Candidate := Config.Maximum_Iterations;
         else
            Candidate := Iteration_Count (Long_Float'Floor (Long_Float (Batch_Iterations) * Scale));
            Candidate := Iteration_Count'Max (Candidate, Batch_Iterations + 1);
            Candidate := Iteration_Count'Min (Candidate, Config.Maximum_Iterations);
         end if;
         Batch_Iterations := Candidate;
      end Increase_Batch;

      procedure Increase_Individual_Batch (Index : Comparison_Case_Index; Elapsed : Long_Float) is
         Iterations : constant Iteration_Count := Case_Iterations (Index);
         Scale      : Long_Float;
         Candidate  : Iteration_Count;
      begin
         if Iterations = Config.Maximum_Iterations then
            return;
         elsif Elapsed <= 0.0 then
            Scale := 2.0;
         else
            Scale := Long_Float'Max (1.25, Case_Target_NS / Elapsed);
            Scale := Long_Float'Min (Scale, 2.0);
         end if;
         if Scale >= Long_Float (Config.Maximum_Iterations) / Long_Float (Iterations) then
            Candidate := Config.Maximum_Iterations;
         else
            Candidate := Iteration_Count (Long_Float'Floor (Long_Float (Iterations) * Scale));
            Candidate := Iteration_Count'Max (Candidate, Iterations + 1);
            Candidate := Iteration_Count'Min (Candidate, Config.Maximum_Iterations);
         end if;
         Case_Iterations (Index) := Candidate;
      end Increase_Individual_Batch;

      procedure Copy_Clock_Metadata (Source : Measurement; Target : in out Measurement) is
      begin
         Target.Timer_Cost := Source.Timer_Cost;
         Target.Median_Timer_Cost := Source.Median_Timer_Cost;
         Target.Clock_Resolution := Source.Clock_Resolution;
         Target.Observed_Resolution := Source.Observed_Resolution;
         Target.Clock_Backend_Id := Source.Clock_Backend_Id;
      end Copy_Clock_Metadata;
   begin
      if Count < Comparison_Case_Count'First or else Count > Comparison_Case_Count'Last then
         raise Constraint_Error with "multi-way comparison requires two to sixteen cases";
      end if;
      Validate_Bootstrap_Work (Config, 2 * Count - 1, "multi-way comparison");
      Result := (others => <>);
      Result.Case_Total := Comparison_Case_Count (Count);
      Result.Schedule_Policy := Config.Shootout_Scheduling;
      Result.Batch_Policy := Config.Comparison_Batching;
      Notify (Config, Starting);
      Prepare_Environment (Config, Watch, Lock);
      Prepare_Operating_Conditions (Config, Watch);
      Await_CPU_Quiescence (Config);
      for Index in 1 .. Count loop
         Result.Data (Comparison_Case_Index (Index)).Sample_Total := Config.Samples;
         Result.Data (Comparison_Case_Index (Index)).Confidence_Level_Value :=
           Config.Confidence_Level_Percent;
         Result.Data (Comparison_Case_Index (Index)).Bootstrap_Resample_Total := Config.Bootstrap_Resamples;
         Result.Data (Comparison_Case_Index (Index)).Random_Seed_Value := Config.Random_Seed;
         Initialize_Metrics (Config, Result.Data (Comparison_Case_Index (Index)));
      end loop;
      Characterize_Clock
        (Backend             => Result.Data (1).Clock_Backend_Id,
         Nominal_Resolution  => Result.Data (1).Clock_Resolution,
         Observed_Resolution => Result.Data (1).Observed_Resolution,
         Minimum_Cost        => Clock_Cost,
         Median_Cost         => Result.Data (1).Median_Timer_Cost);
      Result.Data (1).Timer_Cost := Clock_Cost;
      for Index in 2 .. Count loop
         Copy_Clock_Metadata (Result.Data (1), Result.Data (Comparison_Case_Index (Index)));
      end loop;
      Minimum_Case_NS := Long_Float (Config.Minimum_Sample_Time) * 1_000_000_000.0;
      Case_Target_NS :=
        Long_Float'Max
          (Minimum_Case_NS,
           Long_Float (Config.Measurement_Time)
           * 1_000_000_000.0
           / (Long_Float (Config.Samples) * Long_Float (Count)));
      Target_NS := Case_Target_NS * Long_Float (Count);

      if Config.Warmup_Time > 0.0 then
         declare
            Started  : constant Interfaces.Unsigned_64 := Clock_Now;
            Span     : constant Interfaces.Unsigned_64 := Duration_Nanoseconds (Config.Warmup_Time);
            Deadline : constant Interfaces.Unsigned_64 := Started + Span;
            Current  : Interfaces.Unsigned_64;
            Fastest  : Long_Float;
            Total    : Long_Float;
            Times    : Case_Time_Array;
         begin
            Notify (Config, Warming, 0, 100);
            loop
               Time_Round (Fastest, Total, Times);
               if Config.Comparison_Batching = Equal_Time then
                  for Index in 1 .. Count loop
                     declare
                        Case_Index : constant Comparison_Case_Index := Comparison_Case_Index (Index);
                     begin
                        if Times (Case_Index) < Case_Target_NS * 0.5 then
                           Increase_Individual_Batch (Case_Index, Times (Case_Index));
                        end if;
                     end;
                  end loop;
               elsif (Fastest < Minimum_Case_NS * 0.5 or else Total < Target_NS * 0.5)
                 and then Batch_Iterations < Config.Maximum_Iterations
               then
                  Increase_Batch (Fastest, Total);
               end if;
               Current := Clock_Now;
               Notify
                 (Config,
                  Warming,
                  Natural'Min
                    (100,
                     Natural (Long_Float'Floor (100.0 * Long_Float (Current - Started) / Long_Float (Span)))),
                  100);
               exit when Current >= Deadline;
            end loop;
         end;
      end if;

      Establish_Operating_Baseline (Config, Watch);
      Calibration_Base_Batch := Batch_Iterations;
      Calibration_Base_Cases := Case_Iterations;
      loop
         Batch_Iterations := Calibration_Base_Batch;
         Case_Iterations := Calibration_Base_Cases;
         Calibration_Hits := 0;
         Open_Condition_Window (Watch);
         Notify (Config, Calibrating);
         loop
            declare
               Fastest     : Long_Float;
               Total       : Long_Float;
               Times       : Case_Time_Array;
               All_Settled : Boolean := True;
            begin
               Time_Round (Fastest, Total, Times);
               if Config.Comparison_Batching = Equal_Time then
                  for Index in 1 .. Count loop
                     declare
                        Case_Index : constant Comparison_Case_Index := Comparison_Case_Index (Index);
                     begin
                        if Times (Case_Index) < Case_Target_NS * 0.9
                          and then Case_Iterations (Case_Index) < Config.Maximum_Iterations
                        then
                           All_Settled := False;
                           Increase_Individual_Batch (Case_Index, Times (Case_Index));
                        end if;
                     end;
                  end loop;
                  if All_Settled then
                     Calibration_Hits := Calibration_Hits + 1;
                  else
                     Calibration_Hits := 0;
                  end if;
                  exit when Calibration_Hits >= 3;
               elsif Fastest >= Minimum_Case_NS * 0.9 and then Total >= Target_NS * 0.9 then
                  Calibration_Hits := Calibration_Hits + 1;
               else
                  Calibration_Hits := 0;
               end if;
               if Config.Comparison_Batching = Shared_Iterations then
                  exit when Calibration_Hits >= 3 or else Batch_Iterations = Config.Maximum_Iterations;
                  Increase_Batch (Fastest, Total);
               end if;
            end;
         end loop;
         Validate_After_Calibration (Config, Watch, Recalibrate);
         exit when not Recalibrate;
      end loop;

      Initialize_Perf (Config, Perf);

      declare
         Base_Order        : Order_Array (1 .. Count);
         Positions         : Position_Array (1 .. Count);
         Completed         : Natural := 0;
         Total             : constant Natural := Natural (Config.Samples) * Count;
         Sampling_Started  : Interfaces.Unsigned_64;
         type Collected_Array is array (Comparison_Case_Index) of Natural;
         Collected_By_Case : Collected_Array := [others => 0];

         procedure Collect_One (Case_Number : Positive; Sample : Positive; Position : Positive) is
            Case_Index : constant Comparison_Case_Index := Comparison_Case_Index (Case_Number);
            Probe      : Sample_Probe_State;
            Elapsed    : Long_Float;
         begin
            Start_Sample (Config, Perf, Probe);
            Elapsed := Time_One (Case_Id'Val (Case_Number - 1), Iterations_For (Case_Index));
            Finish_Sample
              (Config,
               Perf,
               Probe,
               Result.Data (Case_Index),
               Sample_Index (Sample),
               Iterations_For (Case_Index),
               Elapsed);
            if Config.Subtract_Timer_Cost and then Elapsed > Clock_Cost then
               Elapsed := Elapsed - Clock_Cost;
            end if;
            Result.Data (Case_Index).Values (Sample_Index (Sample)) :=
              Elapsed / Long_Float (Iterations_For (Case_Index));
            Positions (Case_Number) := Position;
            Collected_By_Case (Case_Index) := Sample;
            Completed := Completed + 1;
            Notify_Case (Case_Id'Val (Case_Number - 1), Sampling, Completed, Total);
         end Collect_One;

         function Sequential_Limit_Reached
           (Started : Interfaces.Unsigned_64; Completed : Natural; Excluded : Interfaces.Unsigned_64 := 0)
            return Boolean
         is
            Elapsed : constant Interfaces.Unsigned_64 := Clock_Now - Started;
         begin
            return
              Config.Maximum_Sampling_Time > 0.0
              and then Completed >= Natural (Sample_Count'First)
              and then Elapsed >= Excluded
              and then Elapsed - Excluded >= Duration_Nanoseconds (Config.Maximum_Sampling_Time / Count);
         end Sequential_Limit_Reached;
      begin
         for Index in Base_Order'Range loop
            Base_Order (Index) := Index;
         end loop;
         if Config.Shootout_Scheduling = Balanced_Rounds then
            for Index in reverse 2 .. Count loop
               declare
                  Other : constant Positive :=
                    Natural (Next_Random (State) mod Interfaces.Unsigned_64 (Index)) + 1;
                  Saved : constant Positive := Base_Order (Index);
               begin
                  Base_Order (Index) := Base_Order (Other);
                  Base_Order (Other) := Saved;
               end;
            end loop;

            Sampling_Started := Clock_Now;
            declare
               Paused_At_Sampling_Start : constant Interfaces.Unsigned_64 := Watch.Paused_Total;
               Total_Rounds             : constant Positive := Natural (Config.Samples);
               --  One unit is a complete balanced round. Interference that
               --  arrives mid-round would otherwise be spread unevenly across
               --  the cases the round is meant to compare fairly.
               Group                    : constant Positive :=
                 Units_Per_Window (Config, Target_NS, Total_Rounds);
               Window_First             : Positive := 1;
               Window_Last              : Positive;
               Action                   : Window_Action;
               Condition_Result         : Condition_Action;
               Recovered                : Boolean;
               Terminal_Window          : Boolean;

               procedure Collect_Round (Sample : Positive) is
               begin
                  for Position in 1 .. Count loop
                     declare
                        Base_Position : constant Positive := ((Position - 1 + Sample - 1) mod Count) + 1;
                        Case_Number   : constant Positive := Base_Order (Base_Position);
                     begin
                        Collect_One (Case_Number, Sample, Position);
                     end;
                  end loop;
                  for Case_Number in 2 .. Count loop
                     Reference_First_Schedule (Comparison_Case_Index (Case_Number), Sample_Index (Sample)) :=
                       Positions (1) < Positions (Case_Number);
                  end loop;
               end Collect_Round;

               procedure Rewarm (Span : Nonnegative_Duration) is
                  Deadline : Interfaces.Unsigned_64;
                  Fastest  : Long_Float;
                  Spent    : Long_Float;
                  Times    : Case_Time_Array;
                  Started  : Interfaces.Unsigned_64;
               begin
                  if Span <= 0.0 then
                     return;
                  end if;
                  Started := Clock_Now;
                  Deadline := Started + Duration_Nanoseconds (Span);
                  Notify (Config, Warming, 0, 100);
                  loop
                     Time_Round (Fastest, Spent, Times);
                     Internal_Probes.Escape (Fastest'Address);
                     Internal_Probes.Escape (Spent'Address);
                     Internal_Probes.Escape (Times'Address);
                     exit when Clock_Now >= Deadline;
                  end loop;
                  Watch.Paused_Total := Watch.Paused_Total + (Clock_Now - Started);
                  Notify (Config, Warming, 100, 100);
               end Rewarm;
            begin
               while Window_First <= Total_Rounds loop
                  Window_Last := Positive'Min (Window_First + Group - 1, Total_Rounds);
                  loop
                     declare
                        type Snapshot_Array is array (Comparison_Case_Index) of Telemetry_Snapshot;
                        Saved : Snapshot_Array;
                     begin
                        for Index in 1 .. Count loop
                           Saved (Comparison_Case_Index (Index)) :=
                             Save_Telemetry (Result.Data (Comparison_Case_Index (Index)));
                        end loop;
                        Open_Interference_Window (Watch);
                        Open_Condition_Window (Watch);
                        for Sample in Window_First .. Window_Last loop
                           Collect_Round (Sample);
                           Collected_Samples := Natural'Max (Collected_Samples, Sample);
                        end loop;
                        Judge_Window
                          (Config, Watch, Sample_Index (Window_First), Sample_Index (Window_Last), Action);
                        Terminal_Window :=
                          Window_Last = Total_Rounds
                          or else Sampling_Limit_Reached
                                    (Config,
                                     Sampling_Started,
                                     Collected_Samples,
                                     Watch.Paused_Total - Paused_At_Sampling_Start);
                        Judge_Condition_Window
                          (Config,
                           Watch,
                           Window_Last - Window_First + 1,
                           Condition_Result,
                           Force_Profile => Terminal_Window);
                        if Condition_Result = Fail_Conditions then
                           raise Operating_Conditions_Unacceptable
                             with "operating conditions changed during balanced comparison";
                        elsif Condition_Result = Pause_For_Conditions then
                           Await_Condition_Settle (Config, Watch, Recovered);
                           if Recovered then
                              Watch.Report.Recollected_Units :=
                                Watch.Report.Recollected_Units + Window_Last - Window_First + 1;
                              Completed := Completed - Count * (Window_Last - Window_First + 1);
                              for Index in 1 .. Count loop
                                 Restore_Telemetry
                                   (Result.Data (Comparison_Case_Index (Index)),
                                    Saved (Comparison_Case_Index (Index)));
                              end loop;
                              if Action = Settle_And_Retake then
                                 Await_Foreign_Settle (Config, Watch);
                                 Rewarm
                                   (Duration'Max
                                      (Config.Operating_Conditions.Rewarm_Time,
                                       Config.Interference.Rewarm_Time));
                              else
                                 Rewarm (Config.Operating_Conditions.Rewarm_Time);
                              end if;
                           elsif Action = Accept_Window then
                              exit;
                           else
                              Completed := Completed - Count * (Window_Last - Window_First + 1);
                              for Index in 1 .. Count loop
                                 Restore_Telemetry
                                   (Result.Data (Comparison_Case_Index (Index)),
                                    Saved (Comparison_Case_Index (Index)));
                              end loop;
                              if Action = Settle_And_Retake then
                                 Await_Foreign_Settle (Config, Watch);
                                 Rewarm (Config.Interference.Rewarm_Time);
                              end if;
                           end if;
                        elsif Action = Accept_Window then
                           exit;
                        else
                           Completed := Completed - Count * (Window_Last - Window_First + 1);
                           for Index in 1 .. Count loop
                              Restore_Telemetry
                                (Result.Data (Comparison_Case_Index (Index)),
                                 Saved (Comparison_Case_Index (Index)));
                           end loop;
                           if Action = Settle_And_Retake then
                              Await_Foreign_Settle (Config, Watch);
                              Rewarm (Config.Interference.Rewarm_Time);
                           end if;
                        end if;
                     end;
                  end loop;
                  exit when Terminal_Window;
                  Window_First := Window_Last + 1;
               end loop;
            end;
         else
            for Case_Number in 1 .. Count loop
               declare
                  Case_Started         : constant Interfaces.Unsigned_64 := Clock_Now;
                  Case_Index           : constant Comparison_Case_Index :=
                    Comparison_Case_Index (Case_Number);
                  Total_Samples        : constant Positive := Natural (Config.Samples);
                  Group                : constant Positive :=
                    Units_Per_Window (Config, Case_Target_NS, Total_Samples);
                  Window_First         : Positive := 1;
                  Window_Last          : Positive;
                  Action               : Window_Action;
                  Condition_Result     : Condition_Action;
                  Recovered            : Boolean;
                  Paused_At_Case_Start : constant Interfaces.Unsigned_64 := Watch.Paused_Total;
                  Reached              : Boolean := False;
                  Terminal_Window      : Boolean;

                  procedure Rewarm (Span : Nonnegative_Duration) is
                     Deadline : Interfaces.Unsigned_64;
                     Elapsed  : Long_Float;
                     Started  : Interfaces.Unsigned_64;
                  begin
                     if Span <= 0.0 then
                        return;
                     end if;
                     Started := Clock_Now;
                     Deadline := Started + Duration_Nanoseconds (Span);
                     Notify (Config, Warming, 0, 100);
                     loop
                        Elapsed := Time_One (Case_Id'Val (Case_Number - 1), Iterations_For (Case_Index));
                        Internal_Probes.Escape (Elapsed'Address);
                        exit when Clock_Now >= Deadline;
                     end loop;
                     Watch.Paused_Total := Watch.Paused_Total + (Clock_Now - Started);
                     Notify (Config, Warming, 100, 100);
                  end Rewarm;
               begin
                  while Window_First <= Total_Samples and then not Reached loop
                     Window_Last := Positive'Min (Window_First + Group - 1, Total_Samples);
                     loop
                        declare
                           Saved : constant Telemetry_Snapshot := Save_Telemetry (Result.Data (Case_Index));
                        begin
                           Open_Interference_Window (Watch);
                           Open_Condition_Window (Watch);
                           for Sample in Window_First .. Window_Last loop
                              Collect_One (Case_Number, Sample, Case_Number);
                           end loop;
                           Judge_Window
                             (Config, Watch, Sample_Index (Window_First), Sample_Index (Window_Last), Action);
                           Terminal_Window :=
                             Window_Last = Total_Samples
                             or else Sequential_Limit_Reached
                                       (Case_Started, Window_Last, Watch.Paused_Total - Paused_At_Case_Start);
                           Judge_Condition_Window
                             (Config,
                              Watch,
                              Window_Last - Window_First + 1,
                              Condition_Result,
                              Force_Profile => Terminal_Window);
                           if Condition_Result = Fail_Conditions then
                              raise Operating_Conditions_Unacceptable
                                with "operating conditions changed during sequential comparison";
                           elsif Condition_Result = Pause_For_Conditions then
                              Await_Condition_Settle (Config, Watch, Recovered);
                              if Recovered then
                                 Watch.Report.Recollected_Units :=
                                   Watch.Report.Recollected_Units + Window_Last - Window_First + 1;
                                 Completed := Completed - (Window_Last - Window_First + 1);
                                 Restore_Telemetry (Result.Data (Case_Index), Saved);
                                 if Action = Settle_And_Retake then
                                    Await_Foreign_Settle (Config, Watch);
                                    Rewarm
                                      (Duration'Max
                                         (Config.Operating_Conditions.Rewarm_Time,
                                          Config.Interference.Rewarm_Time));
                                 else
                                    Rewarm (Config.Operating_Conditions.Rewarm_Time);
                                 end if;
                              elsif Action = Accept_Window then
                                 exit;
                              else
                                 Completed := Completed - (Window_Last - Window_First + 1);
                                 Restore_Telemetry (Result.Data (Case_Index), Saved);
                                 if Action = Settle_And_Retake then
                                    Await_Foreign_Settle (Config, Watch);
                                    Rewarm (Config.Interference.Rewarm_Time);
                                 end if;
                              end if;
                           elsif Action = Accept_Window then
                              exit;
                           else
                              Completed := Completed - (Window_Last - Window_First + 1);
                              Restore_Telemetry (Result.Data (Case_Index), Saved);
                              if Action = Settle_And_Retake then
                                 Await_Foreign_Settle (Config, Watch);
                                 Rewarm (Config.Interference.Rewarm_Time);
                              end if;
                           end if;
                        end;
                     end loop;
                     Reached := Terminal_Window;
                     Window_First := Window_Last + 1;
                  end loop;
                  --  This case's windows are its own, so it keeps its own
                  --  per-sample values rather than the last case's.
                  Result.Data (Case_Index).Foreign_CPU := Watch.Foreign;
                  Watch.Foreign := (others => 0.0);
               end;
            end loop;
            Collected_Samples := Natural (Config.Samples);
            for Index in 1 .. Count loop
               Collected_Samples :=
                 Natural'Min (Collected_Samples, Collected_By_Case (Comparison_Case_Index (Index)));
            end loop;
            for Case_Number in 2 .. Count loop
               for Sample in 1 .. Collected_Samples loop
                  Reference_First_Schedule (Comparison_Case_Index (Case_Number), Sample_Index (Sample)) :=
                    True;
               end loop;
            end loop;
         end if;
      end;

      Finalize_Operating_Conditions (Watch);
      Notify (Config, Analyzing);
      for Index in 1 .. Count loop
         declare
            Case_Index : constant Comparison_Case_Index := Comparison_Case_Index (Index);
         begin
            Result.Data (Case_Index).Sample_Total := Sample_Count (Collected_Samples);
            Result.Data (Case_Index).Iterations := Iterations_For (Case_Index);
            Apply_Environment
              (Watch,
               Result.Data (Case_Index),
               Include_Samples => Config.Shootout_Scheduling = Balanced_Rounds);
            Analyze (Result.Data (Case_Index));
            Analyze_Metrics (Result.Data (Case_Index));
            Analyze_Custom_Metrics (Result.Data (Case_Index));
            Result.Data (Case_Index).Median_Batch :=
              Result.Data (Case_Index).Median * Long_Float (Iterations_For (Case_Index));
         end;
      end loop;
      for Index in 2 .. Count loop
         declare
            Case_Index : constant Comparison_Case_Index := Comparison_Case_Index (Index);
            Pair       : Comparison := (others => <>);
         begin
            Pair.Reference_Data := Result.Data (1);
            Pair.Contender_Data := Result.Data (Case_Index);
            Pair.Practical_Threshold := Config.Practical_Threshold_Percent;
            Pair.Random_Seed_Value := Config.Random_Seed + Long_Long_Integer (Index);
            for Sample in 1 .. Collected_Samples loop
               Pair.Reference_First_Order (Sample_Index (Sample)) :=
                 Reference_First_Schedule (Case_Index, Sample_Index (Sample));
               if Pair.Reference_First_Order (Sample_Index (Sample)) then
                  Pair.Reference_First := Pair.Reference_First + 1;
               else
                  Pair.Contender_First := Pair.Contender_First + 1;
               end if;
            end loop;
            Analyze_Comparison (Pair);
            Result.Against_Reference (Case_Index) := Pair;
         end;
      end loop;
      Notify (Config, Finished, 1, 1);
   end Compare_Many;

   function Iterations_Per_Sample (Result : Measurement) return Iteration_Count
   is (Result.Iterations);

   function Samples (Result : Measurement) return Sample_Count
   is (Result.Sample_Total);

   function Timer_Cost_Nanoseconds (Result : Measurement) return Long_Float
   is (Result.Timer_Cost);

   function Clock_Backend (Result : Measurement) return String is
   begin
      case Result.Clock_Backend_Id is
         when 1      =>
            return "mach_absolute_time";

         when 2      =>
            return "clock_gettime(CLOCK_MONOTONIC_RAW)";

         when others =>
            return "unknown";
      end case;
   end Clock_Backend;

   function Clock_Resolution_Nanoseconds (Result : Measurement) return Long_Float
   is (Result.Clock_Resolution);

   function Observed_Clock_Resolution_Nanoseconds (Result : Measurement) return Long_Float
   is (Result.Observed_Resolution);

   function Median_Timer_Cost_Nanoseconds (Result : Measurement) return Long_Float
   is (Result.Median_Timer_Cost);

   function Median_Batch_Nanoseconds (Result : Measurement) return Long_Float
   is (Result.Median_Batch);

   function Quantization_Floor_Nanoseconds (Result : Measurement) return Long_Float
   is (Result.Clock_Resolution / Long_Float (Result.Iterations));

   function Minimum_Nanoseconds (Result : Measurement) return Long_Float
   is (Result.Minimum);

   function Maximum_Nanoseconds (Result : Measurement) return Long_Float
   is (Result.Maximum);

   function Mean_Nanoseconds (Result : Measurement) return Long_Float
   is (Result.Mean);

   function Median_Nanoseconds (Result : Measurement) return Long_Float
   is (Result.Median);

   function Standard_Deviation_Nanoseconds (Result : Measurement) return Long_Float
   is (Result.Standard_Deviation);

   function Median_Absolute_Deviation_Nanoseconds (Result : Measurement) return Long_Float
   is (Result.MAD);

   function P95_Nanoseconds (Result : Measurement) return Long_Float
   is (Result.P95);

   function P99_Nanoseconds (Result : Measurement) return Long_Float
   is (Result.P99);

   function Mean_Confidence_Low_Nanoseconds (Result : Measurement) return Long_Float
   is (Result.Confidence_Low);

   function Mean_Confidence_High_Nanoseconds (Result : Measurement) return Long_Float
   is (Result.Confidence_High);

   function Confidence_Level_Percent (Result : Measurement) return Confidence_Percentage
   is (Result.Confidence_Level_Value);

   function Bootstrap_Resamples (Result : Measurement) return Bootstrap_Resample_Count
   is (Result.Bootstrap_Resample_Total);

   function Coefficient_Of_Variation_Percent (Result : Measurement) return Long_Float
   is (Result.CV_Percent);

   function Sample_Lag_One_Correlation (Result : Measurement) return Long_Float
   is (Result.Lag_One);

   function Environment (Result : Measurement) return Environment_Report
   is (Result.Environment_Data);

   function Sample_Foreign_CPU_Percent (Result : Measurement; Index : Sample_Index) return Long_Float is
   begin
      if Index > Sample_Index (Result.Sample_Total) then
         raise Constraint_Error with "sample index exceeds the collected sample count";
      end if;
      return Result.Foreign_CPU (Index);
   end Sample_Foreign_CPU_Percent;

   function Outliers (Result : Measurement) return Outlier_Counts
   is (Result.Outlier_Total);

   function Sample_Nanoseconds (Result : Measurement; Index : Sample_Index) return Long_Float is
   begin
      if Index > Result.Sample_Total then
         raise Constraint_Error with "sample index exceeds collected samples";
      end if;
      return Result.Values (Index);
   end Sample_Nanoseconds;

   function Metric_Name (Axis : Metric_Axis) return String is
   begin
      case Axis is
         when Wall_Time                    =>
            return "wall time";

         when Process_CPU_Time             =>
            return "process CPU time";

         when Thread_CPU_Time              =>
            return "thread CPU time";

         when Process_RSS                  =>
            return "process RSS";

         when Process_RSS_Change           =>
            return "process RSS change";

         when Minor_Page_Faults            =>
            return "minor page faults";

         when Major_Page_Faults            =>
            return "major page faults";

         when Voluntary_Context_Switches   =>
            return "voluntary context switches";

         when Involuntary_Context_Switches =>
            return "involuntary context switches";

         when Disk_Read_Bytes              =>
            return "disk read bytes";

         when Disk_Written_Bytes           =>
            return "disk written bytes";

         when Filesystem_Input_Operations  =>
            return "filesystem input ops";

         when Filesystem_Output_Operations =>
            return "filesystem output ops";

         when CPU_Cycles                   =>
            return "CPU cycles";

         when Instructions                 =>
            return "instructions";

         when Instructions_Per_Cycle       =>
            return "IPC";

         when Cache_Misses                 =>
            return "cache misses";

         when Branches                     =>
            return "branches";

         when Branch_Misses                =>
            return "branch misses";

         when Flyology_Dispatches          =>
            return "Flyology dispatches";

         when Flyology_Poll_Batches        =>
            return "Flyology poll batches";

         when Flyology_Poll_Events         =>
            return "Flyology poll events";

         when Flyology_Wakeups             =>
            return "Flyology wakeups";

         when Flyology_Migrations          =>
            return "Flyology migrations";
      end case;
   end Metric_Name;

   function Metric_Unit (Axis : Metric_Axis) return String is
   begin
      case Axis is
         when Wall_Time | Process_CPU_Time | Thread_CPU_Time             =>
            return "ns/op";

         when Process_RSS                                                =>
            return "bytes";

         when Process_RSS_Change | Disk_Read_Bytes | Disk_Written_Bytes  =>
            return "bytes/op";

         when Minor_Page_Faults | Major_Page_Faults                      =>
            return "faults/op";

         when Voluntary_Context_Switches | Involuntary_Context_Switches  =>
            return "switches/op";

         when Filesystem_Input_Operations | Filesystem_Output_Operations =>
            return "I/O ops/op";

         when CPU_Cycles                                                 =>
            return "cycles/op";

         when Instructions                                               =>
            return "instructions/op";

         when Instructions_Per_Cycle                                     =>
            return "instructions/cycle";

         when Cache_Misses                                               =>
            return "misses/op";

         when Branches                                                   =>
            return "branches/op";

         when Branch_Misses                                              =>
            return "misses/op";

         when Flyology_Dispatches
            | Flyology_Poll_Batches
            | Flyology_Poll_Events
            | Flyology_Wakeups
            | Flyology_Migrations                                        =>
            return "events/op";
      end case;
   end Metric_Unit;

   function Scope (Axis : Metric_Axis) return Metric_Scope is
   begin
      case Axis is
         when Wall_Time           =>
            return Batch_Wall_Clock;

         when Thread_CPU_Time
            | CPU_Cycles
            | Instructions
            | Instructions_Per_Cycle
            | Cache_Misses
            | Branches
            | Branch_Misses       =>
            if Axis = Thread_CPU_Time then
               return Current_Native_Thread;
            end if;
            return Native_Task_Tree;

         when Flyology_Dispatches
            | Flyology_Poll_Batches
            | Flyology_Poll_Events
            | Flyology_Wakeups
            | Flyology_Migrations =>
            return Flyology_Runtime;

         when others              =>
            return Benchmark_Process;
      end case;
   end Scope;

   function Direction (Axis : Metric_Axis) return Metric_Direction is
   begin
      case Axis is
         when Instructions_Per_Cycle =>
            return Higher_Is_Better;

         when Process_RSS
            | Instructions
            | Branches
            | Flyology_Dispatches
            | Flyology_Poll_Batches
            | Flyology_Poll_Events
            | Flyology_Wakeups
            | Flyology_Migrations    =>
            return Diagnostic;

         when others                 =>
            return Lower_Is_Better;
      end case;
   end Direction;

   function Metric_Available (Result : Measurement; Axis : Metric_Axis) return Boolean
   is (Result.Metric_Data.Data /= null
       and then Result.Metric_Data.Data.Requested (Axis)
       and then Result.Metric_Data.Data.Available (Axis)
       and then Result.Metric_Data.Data.Summaries (Axis).Available);

   function Metric_Status (Result : Measurement; Axis : Metric_Axis) return Metric_Availability
   is (if Result.Metric_Data.Data = null
       then Metric_Not_Requested
       else Result.Metric_Data.Data.Status (Axis));

   function Metric_Requested (Result : Measurement; Axis : Metric_Axis) return Boolean
   is (Result.Metric_Data.Data /= null and then Result.Metric_Data.Data.Requested (Axis));

   function Metric_Sample (Result : Measurement; Axis : Metric_Axis; Index : Sample_Index) return Long_Float
   is
   begin
      if not Metric_Available (Result, Axis) then
         raise Constraint_Error with "metric axis is unavailable";
      elsif Index > Result.Sample_Total then
         raise Constraint_Error with "metric sample index exceeds collected samples";
      end if;
      return Result.Metric_Data.Data.Values (Axis, Index);
   end Metric_Sample;

   function Metric_Statistics (Result : Measurement; Axis : Metric_Axis) return Metric_Summary is
   begin
      if not Metric_Available (Result, Axis) then
         return (others => <>);
      end if;
      return Result.Metric_Data.Data.Summaries (Axis);
   end Metric_Statistics;

   procedure Require_Custom_Axis (Result : Measurement; Axis : Custom_Metric_Index) is
   begin
      if Result.Custom_Data.Data = null or else Axis > Result.Custom_Data.Data.Count then
         raise Constraint_Error with "custom metric axis is not registered";
      end if;
   end Require_Custom_Axis;

   function Custom_Metric_Total (Result : Measurement) return Custom_Metric_Count
   is (if Result.Custom_Data.Data = null then 0 else Result.Custom_Data.Data.Count);

   function Primary_Timing_Axis (Result : Measurement) return Custom_Metric_Count is
   begin
      for Position in 1 .. Custom_Metric_Total (Result) loop
         if Custom_Metric_Is_Primary_Timing (Result, Custom_Metric_Index (Position)) then
            return Custom_Metric_Count (Position);
         end if;
      end loop;
      return 0;
   end Primary_Timing_Axis;

   function Custom_Metric_Name (Result : Measurement; Axis : Custom_Metric_Index) return String is
   begin
      Require_Custom_Axis (Result, Axis);
      return Descriptor_Name (Result.Custom_Data.Data.Descriptors (Axis));
   end Custom_Metric_Name;

   function Custom_Metric_Unit (Result : Measurement; Axis : Custom_Metric_Index) return String is
   begin
      Require_Custom_Axis (Result, Axis);
      return Descriptor_Unit (Result.Custom_Data.Data.Descriptors (Axis));
   end Custom_Metric_Unit;

   function Custom_Metric_Scope (Result : Measurement; Axis : Custom_Metric_Index) return Metric_Scope is
   begin
      Require_Custom_Axis (Result, Axis);
      return Result.Custom_Data.Data.Descriptors (Axis).Scope_Value;
   end Custom_Metric_Scope;

   function Custom_Metric_Attribution
     (Result : Measurement; Axis : Custom_Metric_Index) return Metric_Attribution is
   begin
      Require_Custom_Axis (Result, Axis);
      return Result.Custom_Data.Data.Descriptors (Axis).Attribution_Value;
   end Custom_Metric_Attribution;

   function Custom_Metric_Direction (Result : Measurement; Axis : Custom_Metric_Index) return Metric_Direction
   is
   begin
      Require_Custom_Axis (Result, Axis);
      return Result.Custom_Data.Data.Descriptors (Axis).Direction_Value;
   end Custom_Metric_Direction;

   function Custom_Metric_Semantics
     (Result : Measurement; Axis : Custom_Metric_Index) return Custom_Sample_Semantics is
   begin
      Require_Custom_Axis (Result, Axis);
      return Result.Custom_Data.Data.Descriptors (Axis).Semantics_Value;
   end Custom_Metric_Semantics;

   function Custom_Metric_Normalization
     (Result : Measurement; Axis : Custom_Metric_Index) return Custom_Normalization is
   begin
      Require_Custom_Axis (Result, Axis);
      return Result.Custom_Data.Data.Descriptors (Axis).Normalization_Value;
   end Custom_Metric_Normalization;

   function Custom_Metric_Comparison
     (Result : Measurement; Axis : Custom_Metric_Index) return Custom_Comparison_Semantics is
   begin
      Require_Custom_Axis (Result, Axis);
      return Result.Custom_Data.Data.Descriptors (Axis).Comparison_Value;
   end Custom_Metric_Comparison;

   function Custom_Metric_Is_Primary_Timing (Result : Measurement; Axis : Custom_Metric_Index) return Boolean
   is
   begin
      Require_Custom_Axis (Result, Axis);
      return Result.Custom_Data.Data.Descriptors (Axis).Primary_Timing_Value;
   end Custom_Metric_Is_Primary_Timing;

   function Custom_Metric_Timing_Source (Result : Measurement; Axis : Custom_Metric_Index) return String is
   begin
      Require_Custom_Axis (Result, Axis);
      return Descriptor_Timing_Source (Result.Custom_Data.Data.Descriptors (Axis));
   end Custom_Metric_Timing_Source;

   function Custom_Metric_Resolution (Result : Measurement; Axis : Custom_Metric_Index) return Long_Float is
   begin
      Require_Custom_Axis (Result, Axis);
      return Result.Custom_Data.Data.Descriptors (Axis).Resolution_Value;
   end Custom_Metric_Resolution;

   function Custom_Metric_Status (Result : Measurement; Axis : Custom_Metric_Index) return Metric_Availability
   is
      Collected     : Natural := 0;
      First_Failure : Metric_Availability := Metric_Not_Requested;
   begin
      Require_Custom_Axis (Result, Axis);
      for Sample in 1 .. Result.Sample_Total loop
         if Result.Custom_Data.Data.Status (Axis, Sample) = Metric_Collected then
            Collected := Collected + 1;
         elsif First_Failure = Metric_Not_Requested then
            First_Failure := Result.Custom_Data.Data.Status (Axis, Sample);
         end if;
      end loop;
      if Collected = Natural (Result.Sample_Total) then
         return Metric_Collected;
      elsif Collected > 0 then
         return Metric_Partially_Collected;
      else
         return First_Failure;
      end if;
   end Custom_Metric_Status;

   function Custom_Metric_Sample
     (Result : Measurement; Axis : Custom_Metric_Index; Index : Sample_Index) return Long_Float is
   begin
      Require_Custom_Axis (Result, Axis);
      if Index > Result.Sample_Total then
         raise Constraint_Error with "sample index exceeds collected samples";
      elsif Result.Custom_Data.Data.Status (Axis, Index) /= Metric_Collected then
         raise Constraint_Error with "custom metric sample is unavailable";
      end if;
      return Result.Custom_Data.Data.Values (Axis, Index);
   end Custom_Metric_Sample;

   function Custom_Metric_Sample_Status
     (Result : Measurement; Axis : Custom_Metric_Index; Index : Sample_Index) return Metric_Availability is
   begin
      Require_Custom_Axis (Result, Axis);
      if Index > Result.Sample_Total then
         raise Constraint_Error with "sample index exceeds collected samples";
      end if;
      return Result.Custom_Data.Data.Status (Axis, Index);
   end Custom_Metric_Sample_Status;

   function Custom_Metric_Statistics (Result : Measurement; Axis : Custom_Metric_Index) return Metric_Summary
   is
   begin
      Require_Custom_Axis (Result, Axis);
      return Result.Custom_Data.Data.Summaries (Axis);
   end Custom_Metric_Statistics;

   function Reference_Measurement (Result : Comparison) return Measurement
   is (Result.Reference_Data);

   function Contender_Measurement (Result : Comparison) return Measurement
   is (Result.Contender_Data);

   function Confidence_Level_Percent (Result : Comparison) return Confidence_Percentage
   is (Result.Reference_Data.Confidence_Level_Value);

   function Bootstrap_Resamples (Result : Comparison) return Bootstrap_Resample_Count
   is (Result.Reference_Data.Bootstrap_Resample_Total);

   function Geometric_Mean_Speedup (Result : Comparison) return Long_Float
   is (Result.Geometric_Speedup);

   function Median_Speedup (Result : Comparison) return Long_Float
   is (Result.Median_Speedup_Value);

   function Speedup_Confidence_Low (Result : Comparison) return Long_Float
   is (Result.Speedup_CI_Low);

   function Speedup_Confidence_High (Result : Comparison) return Long_Float
   is (Result.Speedup_CI_High);

   function Relative_Time_Change_Percent (Result : Comparison) return Long_Float
   is (100.0 * (1.0 / Result.Geometric_Speedup - 1.0));

   function Relative_Time_Change_Confidence_Low (Result : Comparison) return Long_Float
   is (100.0 * (1.0 / Result.Speedup_CI_High - 1.0));

   function Relative_Time_Change_Confidence_High (Result : Comparison) return Long_Float
   is (100.0 * (1.0 / Result.Speedup_CI_Low - 1.0));

   function Verdict (Result : Comparison) return Comparison_Verdict
   is (Result.Verdict_Value);

   function Practical_Threshold_Percent (Result : Comparison) return Long_Float
   is (Result.Practical_Threshold);

   function Order_Effect_Percent (Result : Comparison) return Long_Float
   is (Result.Order_Effect);

   function Lag_One_Correlation (Result : Comparison) return Long_Float
   is (Result.Lag_One);

   function Mean_Time_Difference_Nanoseconds (Result : Comparison) return Long_Float
   is (Result.Mean_Time_Difference);

   function Contender_Wins (Result : Comparison) return Natural
   is (Result.Contender_Win_Total);

   function Reference_Wins (Result : Comparison) return Natural
   is (Result.Reference_Win_Total);

   function Ties (Result : Comparison) return Natural
   is (Result.Tie_Total);

   function Compare_Metric (Result : Comparison; Axis : Metric_Axis) return Metric_Comparison_Result
   is (Result.Metric_Comparisons (Axis));

   function Compare_Custom_Metric
     (Result : Comparison; Axis : Custom_Metric_Index) return Metric_Comparison_Result is
   begin
      Require_Custom_Axis (Result.Reference_Data, Axis);
      Require_Custom_Axis (Result.Contender_Data, Axis);
      return Result.Custom_Comparisons (Axis);
   end Compare_Custom_Metric;

   function Reference_First_Samples (Result : Comparison) return Natural
   is (Result.Reference_First);

   function Contender_First_Samples (Result : Comparison) return Natural
   is (Result.Contender_First);

   function Sample_Speedup (Result : Comparison; Index : Sample_Index) return Long_Float is
   begin
      if Index > Result.Reference_Data.Sample_Total then
         raise Constraint_Error with "sample index exceeds collected comparison samples";
      end if;
      return Result.Speedup_Values (Index);
   end Sample_Speedup;

   function Cases (Result : Multi_Comparison) return Comparison_Case_Count
   is (Result.Case_Total);

   function Shootout_Schedule (Result : Multi_Comparison) return Shootout_Schedule_Policy
   is (Result.Schedule_Policy);

   function Shootout_Batching (Result : Multi_Comparison) return Comparison_Batch_Policy
   is (Result.Batch_Policy);

   function Case_Measurement (Result : Multi_Comparison; Index : Comparison_Case_Index) return Measurement is
   begin
      if Index > Comparison_Case_Index (Result.Case_Total) then
         raise Constraint_Error with "case index exceeds multi-way comparison cases";
      end if;
      return Result.Data (Index);
   end Case_Measurement;

   function Versus_Reference (Result : Multi_Comparison; Index : Comparison_Case_Index) return Comparison is
   begin
      if Index = 1 or else Index > Comparison_Case_Index (Result.Case_Total) then
         raise Constraint_Error with "contender index must select a measured non-reference case";
      end if;
      return Result.Against_Reference (Index);
   end Versus_Reference;

   procedure Do_Not_Optimize (Value : in out Element) is
   begin
      Internal_Probes.Escape (Value'Address);
   end Do_Not_Optimize;

   procedure Clobber_Memory is
   begin
      Internal_Probes.Clobber_Memory;
   end Clobber_Memory;
end Flyology_Bench;
