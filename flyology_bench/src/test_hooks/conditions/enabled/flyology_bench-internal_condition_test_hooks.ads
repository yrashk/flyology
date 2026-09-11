with Flyology_Bench.Internal_Conditions;
with Interfaces;

private package Flyology_Bench.Internal_Condition_Test_Hooks is

   --  Keep this a literal compile-time constant so production selection can
   --  statically remove every hook reference.
   Enabled : constant Boolean := True;

   procedure Reset;
   procedure Reject_Read (Index : Positive);
   procedure Reject_From_Read (Index : Positive);
   procedure Reject_Profile_Read (Index : Positive);
   procedure Change_Process_Profile_From_Read
     (Index : Positive; Profile : Process_Performance_Profile);
   procedure Begin_Throttle_Event (Index : Positive);
   procedure Delay_Read (Index : Positive; Milliseconds : Positive);

   --  Use explicit nanosecond accounting for condition waits while retaining
   --  their real pacing delays.
   procedure Use_Test_Clock;
   function Test_Clock_Active return Boolean;
   function Test_Clock_Now return Interfaces.Unsigned_64;
   procedure Advance_Test_Clock (Nanoseconds : Interfaces.Unsigned_64);

   procedure Use_Linux_Fixture
     (Sysfs_Root                : String;
      PPD_Profile               : String;
      PPD_Profile_Available     : Boolean;
      PPD_Degradation           : String;
      PPD_Degradation_Available : Boolean);
   procedure Use_Capture_Test (Command : String; Argument : String; Timeout_MS : Positive);
   procedure Capture_Test_Result (Success : out Boolean; Output_Length : out Natural);

   function Read_Count return Natural;
   function Profile_Read_Count return Natural;
   function Linux_Fixture_Enabled return Boolean;
   function Linux_Sysfs_Root return String;
   function Linux_PPD_Profile return String;
   function Linux_PPD_Profile_Available return Boolean;
   function Linux_PPD_Degradation return String;
   function Linux_PPD_Degradation_Available return Boolean;
   function Capture_Test_Enabled return Boolean;
   function Capture_Test_Command return String;
   function Capture_Test_Argument return String;
   function Capture_Test_Timeout_MS return Positive;

   procedure Record_Capture_Test_Result (Success : Boolean; Output_Length : Natural);

   procedure Supply
     (Value : out Internal_Conditions.Snapshot; Include_Profile : Boolean; Supplied : out Boolean);

end Flyology_Bench.Internal_Condition_Test_Hooks;
