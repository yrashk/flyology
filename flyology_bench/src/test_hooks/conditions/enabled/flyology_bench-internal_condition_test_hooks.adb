with Ada.Strings.Unbounded;

package body Flyology_Bench.Internal_Condition_Test_Hooks is
   package US renames Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_64;

   Maximum_Reads : constant := 128;
   type Rejection_Map is array (Positive range 1 .. Maximum_Reads) of Boolean;
   type Delay_Map is array (Positive range 1 .. Maximum_Reads) of Natural;

   Rejected_Reads         : Rejection_Map := [others => False];
   Rejected_Profile_Reads : Rejection_Map := [others => False];
   Read_Delays_MS         : Delay_Map := [others => 0];
   Reject_From            : Natural := 0;
   Process_Profile_From   : Natural := 0;
   Changed_Process_Profile : Process_Performance_Profile := Process_Profile_Default;
   Throttle_From          : Natural := 0;
   Reads                  : Natural := 0;
   Profile_Reads          : Natural := 0;
   Test_Clock_Enabled     : Boolean := False;
   Test_Time_NS           : Interfaces.Unsigned_64 := 0;
   Fixture_Active         : Boolean := False;
   Fixture_Sysfs_Root     : US.Unbounded_String;
   Fixture_PPD_Profile    : US.Unbounded_String;
   Fixture_Profile_OK     : Boolean := False;
   Fixture_Degradation    : US.Unbounded_String;
   Fixture_Degradation_OK : Boolean := False;
   Capture_Active         : Boolean := False;
   Capture_Command        : US.Unbounded_String;
   Capture_Argument       : US.Unbounded_String;
   Capture_Timeout_MS     : Positive := 1;
   Capture_Success        : Boolean := False;
   Capture_Output_Length  : Natural := 0;

   procedure Reset is
   begin
      Rejected_Reads := [others => False];
      Rejected_Profile_Reads := [others => False];
      Read_Delays_MS := [others => 0];
      Reject_From := 0;
      Process_Profile_From := 0;
      Changed_Process_Profile := Process_Profile_Default;
      Throttle_From := 0;
      Reads := 0;
      Profile_Reads := 0;
      Test_Clock_Enabled := False;
      Test_Time_NS := 0;
      Fixture_Active := False;
      Fixture_Sysfs_Root := US.Null_Unbounded_String;
      Fixture_PPD_Profile := US.Null_Unbounded_String;
      Fixture_Profile_OK := False;
      Fixture_Degradation := US.Null_Unbounded_String;
      Fixture_Degradation_OK := False;
      Capture_Active := False;
      Capture_Command := US.Null_Unbounded_String;
      Capture_Argument := US.Null_Unbounded_String;
      Capture_Timeout_MS := 1;
      Capture_Success := False;
      Capture_Output_Length := 0;
   end Reset;

   procedure Reject_Read (Index : Positive) is
   begin
      if Index > Maximum_Reads then
         raise Constraint_Error with "condition hook read index exceeds its fixed capacity";
      end if;
      Rejected_Reads (Index) := True;
   end Reject_Read;

   procedure Reject_From_Read (Index : Positive) is
   begin
      Reject_From := Index;
   end Reject_From_Read;

   procedure Reject_Profile_Read (Index : Positive) is
   begin
      if Index > Maximum_Reads then
         raise Constraint_Error with "condition hook profile-read index exceeds its fixed capacity";
      end if;
      Rejected_Profile_Reads (Index) := True;
   end Reject_Profile_Read;

   procedure Change_Process_Profile_From_Read
     (Index : Positive; Profile : Process_Performance_Profile) is
   begin
      if Index > Maximum_Reads then
         raise Constraint_Error with "condition hook process-profile index exceeds its fixed capacity";
      end if;
      Process_Profile_From := Index;
      Changed_Process_Profile := Profile;
   end Change_Process_Profile_From_Read;

   procedure Begin_Throttle_Event (Index : Positive) is
   begin
      if Index > Maximum_Reads then
         raise Constraint_Error with "condition hook throttle index exceeds its fixed capacity";
      end if;
      Throttle_From := Index;
   end Begin_Throttle_Event;

   procedure Delay_Read (Index : Positive; Milliseconds : Positive) is
   begin
      if Index > Maximum_Reads then
         raise Constraint_Error with "condition hook delayed-read index exceeds its fixed capacity";
      end if;
      Read_Delays_MS (Index) := Milliseconds;
   end Delay_Read;

   procedure Use_Test_Clock is
   begin
      Test_Clock_Enabled := True;
      Test_Time_NS := 0;
   end Use_Test_Clock;

   function Test_Clock_Active return Boolean
   is (Test_Clock_Enabled);

   function Test_Clock_Now return Interfaces.Unsigned_64
   is (Test_Time_NS);

   procedure Advance_Test_Clock (Nanoseconds : Interfaces.Unsigned_64) is
   begin
      if Test_Time_NS > Interfaces.Unsigned_64'Last - Nanoseconds then
         raise Constraint_Error with "condition test clock overflow";
      end if;
      Test_Time_NS := Test_Time_NS + Nanoseconds;
   end Advance_Test_Clock;

   procedure Use_Linux_Fixture
     (Sysfs_Root                : String;
      PPD_Profile               : String;
      PPD_Profile_Available     : Boolean;
      PPD_Degradation           : String;
      PPD_Degradation_Available : Boolean) is
   begin
      Fixture_Active := True;
      Fixture_Sysfs_Root := US.To_Unbounded_String (Sysfs_Root);
      Fixture_PPD_Profile := US.To_Unbounded_String (PPD_Profile);
      Fixture_Profile_OK := PPD_Profile_Available;
      Fixture_Degradation := US.To_Unbounded_String (PPD_Degradation);
      Fixture_Degradation_OK := PPD_Degradation_Available;
   end Use_Linux_Fixture;

   procedure Use_Capture_Test (Command : String; Argument : String; Timeout_MS : Positive) is
   begin
      Capture_Active := True;
      Capture_Command := US.To_Unbounded_String (Command);
      Capture_Argument := US.To_Unbounded_String (Argument);
      Capture_Timeout_MS := Timeout_MS;
   end Use_Capture_Test;

   procedure Capture_Test_Result (Success : out Boolean; Output_Length : out Natural) is
   begin
      Success := Capture_Success;
      Output_Length := Capture_Output_Length;
   end Capture_Test_Result;

   function Read_Count return Natural
   is (Reads);

   function Profile_Read_Count return Natural
   is (Profile_Reads);

   function Linux_Fixture_Enabled return Boolean
   is (Fixture_Active);

   function Linux_Sysfs_Root return String
   is (US.To_String (Fixture_Sysfs_Root));

   function Linux_PPD_Profile return String
   is (US.To_String (Fixture_PPD_Profile));

   function Linux_PPD_Profile_Available return Boolean
   is (Fixture_Profile_OK);

   function Linux_PPD_Degradation return String
   is (US.To_String (Fixture_Degradation));

   function Linux_PPD_Degradation_Available return Boolean
   is (Fixture_Degradation_OK);

   function Capture_Test_Enabled return Boolean
   is (Capture_Active);

   function Capture_Test_Command return String
   is (US.To_String (Capture_Command));

   function Capture_Test_Argument return String
   is (US.To_String (Capture_Argument));

   function Capture_Test_Timeout_MS return Positive
   is (Capture_Timeout_MS);

   procedure Record_Capture_Test_Result (Success : Boolean; Output_Length : Natural) is
   begin
      Capture_Success := Success;
      Capture_Output_Length := Output_Length;
   end Record_Capture_Test_Result;

   procedure Supply
     (Value : out Internal_Conditions.Snapshot; Include_Profile : Boolean; Supplied : out Boolean)
   is
      Reject_Live    : Boolean;
      Reject_Profile : Boolean := False;
   begin
      Reads := Reads + 1;
      if Fixture_Active then
         Value := (others => <>);
         Supplied := False;
         return;
      end if;
      if Reads <= Maximum_Reads and then Read_Delays_MS (Reads) > 0 then
         if Test_Clock_Enabled then
            Advance_Test_Clock (Interfaces.Unsigned_64 (Read_Delays_MS (Reads)) * 1_000_000);
         end if;
         delay Duration (Read_Delays_MS (Reads)) / 1_000.0;
      end if;
      if Include_Profile then
         Profile_Reads := Profile_Reads + 1;
         Reject_Profile := Profile_Reads <= Maximum_Reads and then Rejected_Profile_Reads (Profile_Reads);
      end if;
      Reject_Live :=
        (Reads <= Maximum_Reads and then Rejected_Reads (Reads))
        or else (Reject_From /= 0 and then Reads >= Reject_From);
      Value :=
        (Profile_Availability        =>
           (if Include_Profile then Condition_Available else Condition_Unavailable),
         Profile_Detector            => (if Include_Profile then Darwin_PMSet else No_Condition_Detector),
         Profile                     =>
           (if not Include_Profile
            then Profile_Unknown
            elsif Reject_Profile
            then Profile_Reduced
            else Profile_Performance),
         Power_Source                => External_Power,
         Low_Power_Availability      => Condition_Available,
         Low_Power_Detector          => Darwin_Process_Info,
         Low_Power_Mode              => Low_Power_Mode_Disabled,
         Process_Profile_Avail       => Condition_Available,
         Process_Profile_Detector    => Darwin_Process_Info,
         Process_Profile             =>
           (if Process_Profile_From /= 0 and then Reads >= Process_Profile_From
            then Changed_Process_Profile
            else Process_Profile_Default),
         Thermal_Availability        => Condition_Available,
         Thermal_Detector            => Darwin_Process_Info,
         Thermal_State               =>
           (if Reject_Live then Thermal_State_Serious else Thermal_State_Nominal),
         Degradation_Availability    => Condition_Available,
         Degradation                 => Not_Degraded,
         Throttle_Availability       => Condition_Available,
         Throttle_Time_Avail         => Condition_Available,
         Throttle_Detector           => Linux_CPU_Thermal_Throttle,
         Throttle_Total              => (if Throttle_From /= 0 and then Reads >= Throttle_From then 1 else 0),
         Throttle_Time_Total_MS      => 0,
         Throttle_Discontinuous      => False,
         Throttle_Time_Discontinuous => False);
      Supplied := True;
   end Supply;

end Flyology_Bench.Internal_Condition_Test_Hooks;
