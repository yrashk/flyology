--  Disabled operating-condition test seams selected by the owning project.
--  Imported-only declarations make a missed static guard visible without
--  supplying any production implementation.
with Flyology_Bench.Internal_Conditions;
with Interfaces;

private package Flyology_Bench.Internal_Condition_Test_Hooks is

   --  Keep this a literal compile-time constant so GNAT removes guarded calls
   --  even at -O0.
   Enabled : constant Boolean := False;

   function Test_Clock_Active return Boolean
   with Import, External_Name => "flyology_bench_disabled_condition_hook_must_be_elided_clock_active";

   function Test_Clock_Now return Interfaces.Unsigned_64
   with Import, External_Name => "flyology_bench_disabled_condition_hook_must_be_elided_clock_now";

   procedure Advance_Test_Clock (Nanoseconds : Interfaces.Unsigned_64)
   with Import, External_Name => "flyology_bench_disabled_condition_hook_must_be_elided_clock_advance";

   procedure Supply
     (Value : out Internal_Conditions.Snapshot; Include_Profile : Boolean; Supplied : out Boolean)
   with Import, External_Name => "flyology_bench_disabled_condition_hook_must_be_elided_supply";

   function Linux_Fixture_Enabled return Boolean
   with Import, External_Name => "flyology_bench_disabled_condition_hook_must_be_elided_fixture_enabled";

   function Linux_Sysfs_Root return String
   with Import, External_Name => "flyology_bench_disabled_condition_hook_must_be_elided_sysfs_root";

   function Linux_PPD_Profile return String
   with Import, External_Name => "flyology_bench_disabled_condition_hook_must_be_elided_ppd_profile";

   function Linux_PPD_Profile_Available return Boolean
   with
     Import,
     External_Name => "flyology_bench_disabled_condition_hook_must_be_elided_ppd_profile_available";

   function Linux_PPD_Degradation return String
   with Import, External_Name => "flyology_bench_disabled_condition_hook_must_be_elided_ppd_degradation";

   function Linux_PPD_Degradation_Available return Boolean
   with
     Import,
     External_Name => "flyology_bench_disabled_condition_hook_must_be_elided_ppd_degradation_available";

   function Capture_Test_Enabled return Boolean
   with Import, External_Name => "flyology_bench_disabled_condition_hook_must_be_elided_capture_enabled";

   function Capture_Test_Command return String
   with Import, External_Name => "flyology_bench_disabled_condition_hook_must_be_elided_capture_command";

   function Capture_Test_Argument return String
   with Import, External_Name => "flyology_bench_disabled_condition_hook_must_be_elided_capture_argument";

   function Capture_Test_Timeout_MS return Positive
   with Import, External_Name => "flyology_bench_disabled_condition_hook_must_be_elided_capture_timeout";

   procedure Record_Capture_Test_Result (Success : Boolean; Output_Length : Natural)
   with Import, External_Name => "flyology_bench_disabled_condition_hook_must_be_elided_capture_result";

end Flyology_Bench.Internal_Condition_Test_Hooks;
