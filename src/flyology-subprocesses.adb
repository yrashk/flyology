with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Unchecked_Deallocation;
with Flyology.Subprocess_Test_Hooks;
with GNAT.OS_Lib;
with Interfaces.C.Strings;
with System;

package body Flyology.Subprocesses is
   package C renames Interfaces.C;
   package CS renames Interfaces.C.Strings;
   package US renames Ada.Strings.Unbounded;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type C.long;
   use type CS.chars_ptr;

   procedure Free_Reaper is new Ada.Unchecked_Deallocation (Reaper_Task, Reaper_Access);
   procedure Free_Exit_State is new Ada.Unchecked_Deallocation (Exit_Control, Exit_Control_Access);

   procedure Free_Orphan is new Ada.Unchecked_Deallocation (Orphan_Node, Orphan_Access);

   protected Orphans is
      procedure Add (Item : Orphan_Access);
      procedure Take_Completed (Item : out Orphan_Access);
      function Pending return Boolean;
   private
      Head : Orphan_Access := null;
   end Orphans;

   protected body Orphans is
      procedure Add (Item : Orphan_Access) is
      begin
         Item.Next := Head;
         Head := Item;
      end Add;

      procedure Take_Completed (Item : out Orphan_Access) is
         Previous : Orphan_Access := null;
         Current  : Orphan_Access := Head;
      begin
         Item := null;
         while Current /= null loop
            if Current.Reaper'Terminated then
               Item := Current;
               if Previous = null then
                  Head := Current.Next;
               else
                  Previous.Next := Current.Next;
               end if;
               Item.Next := null;
               return;
            end if;
            Previous := Current;
            Current := Current.Next;
         end loop;
      end Take_Completed;

      function Pending return Boolean
      is (Head /= null);
   end Orphans;

   --  One native collector reclaims abandoned reapers after their child exits.
   task Orphan_Collector is
      pragma Task_Info (Flyology.Native_Task);
      entry Wake;
   end Orphan_Collector;

   task body Orphan_Collector is
      Item : Orphan_Access;
   begin
      loop
         Orphans.Take_Completed (Item);
         if Item /= null then
            Free_Reaper (Item.Reaper);
            Item.State.Release;
            Free_Exit_State (Item.State);
            Free_Orphan (Item);
         elsif Orphans.Pending then
            select
               accept Wake;
            or
               delay 0.01;
            end select;
         else
            select
               accept Wake;
            or
               terminate;
            end select;
         end if;
      end loop;
   end Orphan_Collector;

   type Descriptor_Pair is array (Natural range 0 .. 1) of aliased C.int with Convention => C;
   type Chars_Ptr_Array is array (Natural range <>) of aliased CS.chars_ptr with Convention => C;

   function C_Pipe (Descriptors : System.Address) return C.int;
   pragma Import (C, C_Pipe, "flyology_subprocess_pipe");

   function C_Set_Nonblocking (Descriptor : C.int) return C.int;
   pragma Import (C, C_Set_Nonblocking, "flyology_subprocess_set_nonblocking");

   function C_Set_No_Sigpipe (Descriptor : C.int) return C.int;
   pragma Import (C, C_Set_No_Sigpipe, "flyology_subprocess_set_no_sigpipe");

   function C_Spawn
     (Pid                  : access C.int;
      Executable           : CS.chars_ptr;
      Arguments            : System.Address;
      Explicit_Environment : C.int;
      Environment          : System.Address;
      Working_Directory    : CS.chars_ptr;
      Search_Path          : C.int;
      Stdin_Read           : C.int;
      Stdin_Write          : C.int;
      Stdout_Read          : C.int;
      Stdout_Write         : C.int;
      Stderr_Read          : C.int;
      Stderr_Write         : C.int;
      Control_Parent       : C.int;
      Control_Child        : C.int;
      Capability_Parent    : C.int;
      Capability_Child     : C.int;
      Control_Target       : C.int;
      Capability_Target    : C.int) return C.int;
   pragma Import (C, C_Spawn, "flyology_subprocess_spawn");

   --  Bootstrap publishes these stable child descriptors. Keep the launch
   --  policy in Ada; C only assembles the opaque posix_spawn file actions.
   Child_Control_Target    : constant C.int := 3;
   Child_Capability_Target : constant C.int := 4;

   function C_Observe_Exit (Pid : C.int) return C.int;
   pragma Import (C, C_Observe_Exit, "flyology_subprocess_observe_exit");

   function C_Read (Descriptor : C.int; Buffer : System.Address; Length : C.size_t) return C.long;
   pragma Import (C, C_Read, "read");

   function C_Write_No_Sigpipe (Descriptor : C.int; Buffer : System.Address; Length : C.size_t) return C.long;
   pragma Import (C, C_Write_No_Sigpipe, "flyology_subprocess_write_no_sigpipe");

   function C_Close (Descriptor : C.int) return C.int;
   pragma Import (C, C_Close, "close");

   function C_Kill (Pid, Signal : C.int) return C.int;
   pragma Import (C, C_Kill, "kill");

   function C_Waitpid (Pid : C.int; Status : access C.int; Options : C.int) return C.int;
   pragma Import (C, C_Waitpid, "waitpid");

   function C_Signal_Interrupt return C.int;
   pragma Import (C, C_Signal_Interrupt, "flyology_subprocess_signal_interrupt");
   function C_Signal_Terminate return C.int;
   pragma Import (C, C_Signal_Terminate, "flyology_subprocess_signal_terminate");
   function C_Signal_Kill return C.int;
   pragma Import (C, C_Signal_Kill, "flyology_subprocess_signal_kill");
   function C_Errno_Interrupted return C.int;
   pragma Import (C, C_Errno_Interrupted, "flyology_subprocess_errno_interrupted");
   function C_Errno_Would_Block return C.int;
   pragma Import (C, C_Errno_Would_Block, "flyology_subprocess_errno_would_block");
   function C_Errno_Broken_Pipe return C.int;
   pragma Import (C, C_Errno_Broken_Pipe, "flyology_subprocess_errno_broken_pipe");
   function C_Errno_No_Such_Process return C.int;
   pragma Import (C, C_Errno_No_Such_Process, "flyology_subprocess_errno_no_such_process");
   function C_Errno_Permission return C.int;
   pragma Import (C, C_Errno_Permission, "flyology_subprocess_errno_permission");

   function C_Status_Exited (Status : C.int) return C.int;
   pragma Import (C, C_Status_Exited, "flyology_subprocess_status_exited");
   function C_Status_Exit_Code (Status : C.int) return C.int;
   pragma Import (C, C_Status_Exit_Code, "flyology_subprocess_status_exit_code");
   function C_Status_Signaled (Status : C.int) return C.int;
   pragma Import (C, C_Status_Signaled, "flyology_subprocess_status_signaled");
   function C_Status_Signal (Status : C.int) return C.int;
   pragma Import (C, C_Status_Signal, "flyology_subprocess_status_signal");
   function C_Status_Core_Dumped (Status : C.int) return C.int;
   pragma Import (C, C_Status_Core_Dumped, "flyology_subprocess_status_core_dumped");

   Interrupted_Error : constant C.int := C_Errno_Interrupted;
   Would_Block_Error : constant C.int := C_Errno_Would_Block;
   Broken_Pipe_Error : constant C.int := C_Errno_Broken_Pipe;
   No_Process_Error  : constant C.int := C_Errno_No_Such_Process;
   Permission_Error  : constant C.int := C_Errno_Permission;

   function Contains_NUL (Value : String) return Boolean is
   begin
      for Element of Value loop
         if Element = Character'Val (0) then
            return True;
         end if;
      end loop;
      return False;
   end Contains_NUL;

   function Valid_Environment_Name (Name : String) return Boolean is
   begin
      if Name'Length = 0 or else Contains_NUL (Name) then
         return False;
      end if;
      for Element of Name loop
         if Element = '=' then
            return False;
         end if;
      end loop;
      return True;
   end Valid_Environment_Name;

   procedure Require_Command (Item : Command) is
   begin
      if US.Length (Item.Executable) = 0 then
         raise Program_Error with "command was not constructed by To_Command";
      end if;
   end Require_Command;

   function To_Command (Executable : String) return Command is
      Result : Command;
   begin
      if Executable'Length = 0 or else Contains_NUL (Executable) then
         raise Constraint_Error with "invalid subprocess executable";
      end if;
      Result.Executable := US.To_Unbounded_String (Executable);
      return Result;
   end To_Command;

   procedure Append_Argument (Item : in out Command; Value : String) is
   begin
      Require_Command (Item);
      if Contains_NUL (Value) then
         raise Constraint_Error with "subprocess argument contains NUL";
      end if;
      Item.Arguments.Append (Value);
   end Append_Argument;

   procedure Clear_Arguments (Item : in out Command) is
   begin
      Require_Command (Item);
      Item.Arguments.Clear;
   end Clear_Arguments;

   procedure Set_Path_Search (Item : in out Command; Enabled : Boolean := True) is
   begin
      Require_Command (Item);
      Item.Search_Path := Enabled;
   end Set_Path_Search;

   procedure Set_Working_Directory (Item : in out Command; Directory : String) is
   begin
      Require_Command (Item);
      if Directory'Length = 0 or else Contains_NUL (Directory) then
         raise Constraint_Error with "invalid subprocess working directory";
      end if;
      Item.Working_Directory := US.To_Unbounded_String (Directory);
      Item.Has_Directory := True;
   end Set_Working_Directory;

   procedure Inherit_Working_Directory (Item : in out Command) is
   begin
      Require_Command (Item);
      Item.Working_Directory := US.Null_Unbounded_String;
      Item.Has_Directory := False;
   end Inherit_Working_Directory;

   procedure Clear_Environment (Item : in out Command) is
   begin
      Require_Command (Item);
      Item.Environment.Clear;
      Item.Explicit_Environment := True;
   end Clear_Environment;

   procedure Inherit_Environment (Item : in out Command) is
   begin
      Require_Command (Item);
      Item.Environment.Clear;
      Item.Explicit_Environment := False;
   end Inherit_Environment;

   procedure Set_Environment_Variable (Item : in out Command; Name, Value : String) is
   begin
      Require_Command (Item);
      if not Valid_Environment_Name (Name) or else Contains_NUL (Value) then
         raise Constraint_Error with "invalid subprocess environment variable";
      end if;
      Item.Explicit_Environment := True;
      for Index in Item.Environment.First_Index .. Item.Environment.Last_Index loop
         if US.To_String (Item.Environment (Index).Name) = Name then
            Item.Environment.Replace_Element
              (Index, (Name => US.To_Unbounded_String (Name), Value => US.To_Unbounded_String (Value)));
            return;
         end if;
      end loop;
      Item.Environment.Append
        ((Name => US.To_Unbounded_String (Name), Value => US.To_Unbounded_String (Value)));
   end Set_Environment_Variable;

   protected body Exit_Control is
      procedure Prepare is
      begin
         Wake_Sources.Release (Wake);
         Wake_Sources.Ensure (Wake);
         Is_Done := False;
         Exit_Observed := False;
         Has_Failed := False;
         Status_Value := 0;
         Error_Value := 0;
      end Prepare;

      procedure Release is
      begin
         Wake_Sources.Release (Wake);
         Is_Done := False;
         Exit_Observed := False;
         Has_Failed := False;
         Status_Value := 0;
         Error_Value := 0;
      end Release;

      procedure Mark_Exit_Observed is
      begin
         Exit_Observed := True;
      end Mark_Exit_Observed;

      procedure Send_Group_Signal (Pid, Signal : C.int; Error_Code : out C.int) is
         Result : C.int;
      begin
         --  Hold the exit-state lock through kill so observation cannot pass
         --  between the liveness decision and the system call.
         Error_Code := 0;
         if Exit_Observed or else Is_Done then
            return;
         end if;
         if Flyology.Subprocess_Test_Hooks.Enabled then
            if Flyology.Subprocess_Test_Hooks.Fail_Group_Signal then
               Error_Code := Permission_Error;
               return;
            end if;
            Flyology.Subprocess_Test_Hooks.Note_Group_Signal;
         end if;
         Result := C_Kill (-Pid, Signal);
         if Result /= 0 then
            Error_Code := C.int (GNAT.OS_Lib.Errno);
         end if;
      end Send_Group_Signal;

      procedure Complete (Raw_Status, Error_Code : C.int) is
      begin
         Status_Value := Raw_Status;
         Error_Value := Error_Code;
         Has_Failed := Error_Code /= 0;
         Is_Done := True;
         Wake_Sources.Signal (Wake);
      end Complete;

      procedure Snapshot (Done, Failed : out Boolean; Raw_Status, Error_Code : out C.int) is
      begin
         Done := Is_Done;
         Failed := Has_Failed;
         Raw_Status := Status_Value;
         Error_Code := Error_Value;
      end Snapshot;

      function Completed return Boolean
      is (Is_Done);

      function Wait_Descriptor return IO.Descriptor
      is (Wake_Sources.Descriptor (Wake));
   end Exit_Control;

   task body Reaper_Task is
      Error_Code : C.int;
      Raw_Status : aliased C.int := 0;
      Result     : C.int;
   begin
      loop
         Error_Code := C_Observe_Exit (Pid);
         exit when Error_Code = 0 or else Error_Code /= Interrupted_Error;
      end loop;
      --  waitid(WNOWAIT) keeps the root's ID reserved until waitpid. Exclude
      --  new group signals before that reap, including the later status gap.
      State.Mark_Exit_Observed;
      if Error_Code = 0 then
         Result := C_Kill (-Pid, C_Signal_Kill);
         if Result /= 0
           and then C.int (GNAT.OS_Lib.Errno) /= No_Process_Error
           and then C.int (GNAT.OS_Lib.Errno) /= Permission_Error
         then
            Error_Code := C.int (GNAT.OS_Lib.Errno);
         end if;
      end if;
      if Error_Code = 0 then
         loop
            Result := C_Waitpid (Pid, Raw_Status'Access, 0);
            exit when Result = Pid;
            if Result < 0 and then C.int (GNAT.OS_Lib.Errno) = Interrupted_Error then
               null;
            else
               Error_Code := C.int (GNAT.OS_Lib.Errno);
               exit;
            end if;
         end loop;
      end if;
      if Flyology.Subprocess_Test_Hooks.Enabled then
         Flyology.Subprocess_Test_Hooks.After_Reap;
      end if;
      State.Complete (Raw_Status, Error_Code);
   exception
      when others =>
         State.Complete (0, -1);
   end Reaper_Task;

   procedure Close_Descriptor (Descriptor : in out IO.Descriptor) is
      Ignored : C.int;
   begin
      if Descriptor >= 0 then
         Ignored := C_Close (Descriptor);
         Descriptor := IO.Invalid_Descriptor;
      end if;
   end Close_Descriptor;

   procedure Free_C_Strings (Items : in out Chars_Ptr_Array) is
   begin
      for Item of Items loop
         if Item /= CS.Null_Ptr then
            CS.Free (Item);
         end if;
      end loop;
   end Free_C_Strings;

   procedure Spawn_Internal
     (Item              : Command;
      Child             : in out Process;
      Control_Parent    : C.int;
      Control_Child     : C.int;
      Capability_Parent : C.int;
      Capability_Child  : C.int;
      Pipe_Output       : Boolean := True;
      Pipe_Error        : Boolean := True)
   is
      Stdin_Ends   : aliased Descriptor_Pair := (others => -1);
      Stdout_Ends  : aliased Descriptor_Pair := (others => -1);
      Stderr_Ends  : aliased Descriptor_Pair := (others => -1);
      Pid          : aliased C.int := -1;
      Spawn_Result : C.int := 0;

      procedure Cleanup_Ends is
      begin
         for Descriptor of Stdin_Ends loop
            Close_Descriptor (Descriptor);
         end loop;
         for Descriptor of Stdout_Ends loop
            Close_Descriptor (Descriptor);
         end loop;
         for Descriptor of Stderr_Ends loop
            Close_Descriptor (Descriptor);
         end loop;
      end Cleanup_Ends;
   begin
      Require_Command (Item);
      if Is_Open (Child) then
         raise Program_Error with "subprocess owner is already open";
      elsif not ((Control_Parent = -1
                  and then Control_Child = -1
                  and then Capability_Parent = -1
                  and then Capability_Child = -1)
                 or else (Control_Parent > 4
                          and then Control_Child > 4
                          and then Capability_Parent > 4
                          and then Capability_Child > 4
                          and then Control_Parent /= Control_Child
                          and then Control_Parent /= Capability_Parent
                          and then Control_Parent /= Capability_Child
                          and then Control_Child /= Capability_Parent
                          and then Control_Child /= Capability_Child
                          and then Capability_Parent /= Capability_Child))
      then
         raise Program_Error with "invalid subprocess bootstrap descriptor set";
      end if;
      if C_Pipe (Stdin_Ends'Address) /= 0
        or else (Pipe_Output and then C_Pipe (Stdout_Ends'Address) /= 0)
        or else (Pipe_Error and then C_Pipe (Stderr_Ends'Address) /= 0)
        or else C_Set_No_Sigpipe (Stdin_Ends (1)) /= 0
        or else C_Set_Nonblocking (Stdin_Ends (1)) /= 0
        or else (Pipe_Output and then C_Set_Nonblocking (Stdout_Ends (0)) /= 0)
        or else (Pipe_Error and then C_Set_Nonblocking (Stderr_Ends (0)) /= 0)
      then
         Cleanup_Ends;
         raise Spawn_Error with "cannot create subprocess pipes, errno=" & GNAT.OS_Lib.Errno'Image;
      end if;

      declare
         Argument_Count    : constant Natural := Natural (Item.Arguments.Length);
         Environment_Count : constant Natural := Natural (Item.Environment.Length);
         Arguments         : Chars_Ptr_Array (0 .. Argument_Count + 1) := (others => CS.Null_Ptr);
         Environment       : Chars_Ptr_Array (0 .. Environment_Count) := (others => CS.Null_Ptr);
         Executable        : CS.chars_ptr := CS.New_String (US.To_String (Item.Executable));
         Directory         : CS.chars_ptr := CS.Null_Ptr;
      begin
         Arguments (0) := CS.New_String (US.To_String (Item.Executable));
         for Index in 1 .. Argument_Count loop
            Arguments (Index) := CS.New_String (Item.Arguments.Element (Positive (Index)));
         end loop;
         for Index in 1 .. Environment_Count loop
            declare
               Variable : constant Environment_Entry := Item.Environment.Element (Positive (Index));
            begin
               Environment (Index - 1) :=
                 CS.New_String (US.To_String (Variable.Name) & "=" & US.To_String (Variable.Value));
            end;
         end loop;
         if Item.Has_Directory then
            Directory := CS.New_String (US.To_String (Item.Working_Directory));
         end if;

         Spawn_Result :=
           C_Spawn
             (Pid'Access,
              Executable,
              Arguments'Address,
              (if Item.Explicit_Environment then 1 else 0),
              Environment'Address,
              Directory,
              (if Item.Search_Path then 1 else 0),
              Stdin_Ends (0),
              Stdin_Ends (1),
              Stdout_Ends (0),
              Stdout_Ends (1),
              Stderr_Ends (0),
              Stderr_Ends (1),
              Control_Parent,
              Control_Child,
              Capability_Parent,
              Capability_Child,
              Child_Control_Target,
              Child_Capability_Target);

         CS.Free (Directory);
         CS.Free (Executable);
         Free_C_Strings (Environment);
         Free_C_Strings (Arguments);
      exception
         when others =>
            CS.Free (Directory);
            CS.Free (Executable);
            Free_C_Strings (Environment);
            Free_C_Strings (Arguments);
            Cleanup_Ends;
            raise;
      end;

      if Spawn_Result /= 0 then
         Cleanup_Ends;
         raise Spawn_Error with "posix_spawn failed, error=" & Spawn_Result'Image;
      end if;

      begin
         Child.Exit_State := new Exit_Control;
         Child.Exit_State.Prepare;
      exception
         when others =>
            declare
               Ignored : C.int := C_Kill (-Pid, C_Signal_Kill);
               Raw     : aliased C.int;
               pragma Unreferenced (Ignored);
            begin
               while C_Waitpid (Pid, Raw'Access, 0) < 0 and then C.int (GNAT.OS_Lib.Errno) = Interrupted_Error
               loop
                  null;
               end loop;
            end;
            if Child.Exit_State /= null then
               Child.Exit_State.Release;
               Free_Exit_State (Child.Exit_State);
            end if;
            Cleanup_Ends;
            raise Spawn_Error with "cannot create subprocess exit readiness source";
      end;

      Close_Descriptor (Stdin_Ends (0));
      Close_Descriptor (Stdout_Ends (1));
      Close_Descriptor (Stderr_Ends (1));
      Child.Pid_Value := Pid;
      Child.Input_FD := Stdin_Ends (1);
      Child.Output_FD := Stdout_Ends (0);
      Child.Error_FD := Stderr_Ends (0);
      Stdin_Ends (1) := -1;
      Stdout_Ends (0) := -1;
      Stderr_Ends (0) := -1;

      begin
         Child.Orphan := new Orphan_Node;
         if Flyology.Subprocess_Test_Hooks.Enabled
           and then Flyology.Subprocess_Test_Hooks.Fail_Reaper_Allocation
         then
            raise Storage_Error with "injected subprocess reaper failure";
         end if;
         Child.Reaper := new Reaper_Task (Pid, Child.Exit_State);
      exception
         when others =>
            declare
               Ignored : C.int := C_Kill (-Pid, C_Signal_Kill);
               Raw     : aliased C.int;
               pragma Unreferenced (Ignored);
            begin
               while C_Waitpid (Pid, Raw'Access, 0) < 0 and then C.int (GNAT.OS_Lib.Errno) = Interrupted_Error
               loop
                  null;
               end loop;
            end;
            Close_Descriptor (Child.Input_FD);
            Close_Descriptor (Child.Output_FD);
            Close_Descriptor (Child.Error_FD);
            Free_Orphan (Child.Orphan);
            Child.Exit_State.Release;
            Free_Exit_State (Child.Exit_State);
            Child.Pid_Value := -1;
            raise Spawn_Error with "cannot allocate subprocess reaper";
      end;
   exception
      when others =>
         Cleanup_Ends;
         raise;
   end Spawn_Internal;

   procedure Spawn (Item : Command; Child : in out Process) is
   begin
      Spawn_Internal (Item, Child, -1, -1, -1, -1);
   end Spawn;

   function Is_Open (Child : Process) return Boolean
   is (Child.Pid_Value > 0);

   function Has_Exited (Child : Process) return Boolean is
   begin
      if not Is_Open (Child) then
         raise Program_Error with "subprocess owner is closed";
      end if;
      return Child.Exit_State.Completed;
   end Has_Exited;

   function Identifier (Child : Process) return Process_Id is
   begin
      if not Is_Open (Child) then
         raise Program_Error with "subprocess owner is closed";
      end if;
      return Process_Id (Child.Pid_Value);
   end Identifier;

   function Standard_Input_Is_Open (Child : Process) return Boolean
   is (Child.Input_FD >= 0);
   function Standard_Output_Is_Open (Child : Process) return Boolean
   is (Child.Output_FD >= 0);
   function Standard_Error_Is_Open (Child : Process) return Boolean
   is (Child.Error_FD >= 0);

   procedure Close_Standard_Input (Child : in out Process) is
   begin
      Close_Descriptor (Child.Input_FD);
   end Close_Standard_Input;
   procedure Close_Standard_Output (Child : in out Process) is
   begin
      Close_Descriptor (Child.Output_FD);
   end Close_Standard_Output;
   procedure Close_Standard_Error (Child : in out Process) is
   begin
      Close_Descriptor (Child.Error_FD);
   end Close_Standard_Error;

   function Remaining (Started : Ada.Real_Time.Time; Timeout : Duration) return Duration is
      Elapsed : constant Duration := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
   begin
      if Timeout < 0.0 then
         return IO.Infinite;
      elsif Elapsed >= Timeout then
         return 0.0;
      else
         return Timeout - Elapsed;
      end if;
   end Remaining;

   procedure Wait_Ready
     (Descriptor : IO.Descriptor;
      Condition  : IO.Wait_Kind;
      Timeout    : Duration;
      Token      : access Cancellation.Token)
   is
      Wake_FD   : C.int := -1;
      Requested : Boolean := False;
   begin
      if Token = null then
         if not IO.Wait (Descriptor, Condition, Timeout) then
            raise IO.Timeout_Error with "subprocess pipe deadline expired";
         end if;
      else
         Token.Wait_Source (Wake_FD, Requested);
         if Requested then
            raise Cancellation.Operation_Cancelled;
         end if;
         declare
            Interrupts : constant IO.Interrupt_Set (1 .. 1) := (1 => Wake_FD);
         begin
            case IO.Wait_Interruptibly (Descriptor, Condition, Timeout, Interrupts) is
               when IO.Ready       =>
                  null;

               when IO.Timed_Out   =>
                  raise IO.Timeout_Error with "subprocess pipe deadline expired";

               when IO.Interrupted =>
                  raise Cancellation.Operation_Cancelled;
            end case;
         end;
      end if;
   end Wait_Ready;

   procedure Read_Pipe
     (Descriptor : in out IO.Descriptor;
      Item       : out Ada.Streams.Stream_Element_Array;
      Last       : out Ada.Streams.Stream_Element_Offset;
      Timeout    : Duration;
      Token      : access Cancellation.Token)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Result  : C.long;
   begin
      Last := Item'First - 1;
      if Descriptor < 0 then
         raise Pipe_Error with "subprocess output pipe is closed";
      elsif Item'Length = 0 then
         return;
      end if;
      loop
         Result := C_Read (Descriptor, Item'Address, C.size_t (Item'Length));
         if Result > 0 then
            Last := Item'First + Ada.Streams.Stream_Element_Offset (Result) - 1;
            return;
         elsif Result = 0 then
            Close_Descriptor (Descriptor);
            return;
         elsif C.int (GNAT.OS_Lib.Errno) = Interrupted_Error then
            null;
         elsif C.int (GNAT.OS_Lib.Errno) = Would_Block_Error then
            Wait_Ready (Descriptor, IO.For_Read, Remaining (Started, Timeout), Token);
         else
            raise Pipe_Error with "subprocess pipe read failed, errno=" & GNAT.OS_Lib.Errno'Image;
         end if;
      end loop;
   end Read_Pipe;

   procedure Write_Pipe
     (Descriptor    : IO.Descriptor;
      Item          : Ada.Streams.Stream_Element_Array;
      Last          : out Ada.Streams.Stream_Element_Offset;
      Timeout       : Duration;
      Token         : access Cancellation.Token;
      Reader_Closed : out Boolean)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Result  : C.long;
   begin
      Last := Item'First - 1;
      Reader_Closed := False;
      if Descriptor < 0 then
         raise Pipe_Error with "subprocess input pipe is closed";
      elsif Item'Length = 0 then
         return;
      end if;
      loop
         Result := C_Write_No_Sigpipe (Descriptor, Item'Address, C.size_t (Item'Length));
         if Result > 0 then
            Last := Item'First + Ada.Streams.Stream_Element_Offset (Result) - 1;
            return;
         elsif Result = 0 then
            raise Pipe_Error with "subprocess pipe write made no progress";
         elsif C.int (GNAT.OS_Lib.Errno) = Interrupted_Error then
            null;
         elsif C.int (GNAT.OS_Lib.Errno) = Would_Block_Error then
            Wait_Ready (Descriptor, IO.For_Write, Remaining (Started, Timeout), Token);
         elsif C.int (GNAT.OS_Lib.Errno) = Broken_Pipe_Error then
            Reader_Closed := True;
            return;
         else
            raise Pipe_Error with "subprocess pipe write failed, errno=" & GNAT.OS_Lib.Errno'Image;
         end if;
      end loop;
   end Write_Pipe;

   procedure Read_Standard_Output
     (Child   : in out Process;
      Item    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration := IO.Infinite;
      Token   : access Cancellation.Token := null) is
   begin
      Read_Pipe (Child.Output_FD, Item, Last, Timeout, Token);
   exception
      when IO.Device_Error =>
         raise Pipe_Error with "subprocess stdout readiness wait failed";
   end Read_Standard_Output;

   procedure Read_Standard_Error
     (Child   : in out Process;
      Item    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration := IO.Infinite;
      Token   : access Cancellation.Token := null) is
   begin
      Read_Pipe (Child.Error_FD, Item, Last, Timeout, Token);
   exception
      when IO.Device_Error =>
         raise Pipe_Error with "subprocess stderr readiness wait failed";
   end Read_Standard_Error;

   procedure Write_Standard_Input
     (Child   : in out Process;
      Item    : Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration := IO.Infinite;
      Token   : access Cancellation.Token := null)
   is
      Reader_Closed : Boolean;
   begin
      Try_Write_Standard_Input (Child, Item, Last, Reader_Closed, Timeout, Token);
      if Reader_Closed then
         raise Pipe_Error with "subprocess pipe write failed, errno=" & Broken_Pipe_Error'Image;
      end if;
   end Write_Standard_Input;

   procedure Try_Write_Standard_Input
     (Child         : in out Process;
      Item          : Ada.Streams.Stream_Element_Array;
      Last          : out Ada.Streams.Stream_Element_Offset;
      Reader_Closed : out Boolean;
      Timeout       : Duration := IO.Infinite;
      Token         : access Cancellation.Token := null) is
   begin
      Write_Pipe (Child.Input_FD, Item, Last, Timeout, Token, Reader_Closed);
   exception
      when IO.Device_Error =>
         raise Pipe_Error with "subprocess stdin readiness wait failed";
   end Try_Write_Standard_Input;

   function Decode (Raw_Status : C.int) return Exit_Status is
   begin
      if C_Status_Exited (Raw_Status) /= 0 then
         return
           (Kind        => Exited,
            Code        => Natural (C_Status_Exit_Code (Raw_Status)),
            Signal      => 0,
            Core_Dumped => False);
      elsif C_Status_Signaled (Raw_Status) /= 0 then
         return
           (Kind        => Signaled,
            Code        => 0,
            Signal      => Natural (C_Status_Signal (Raw_Status)),
            Core_Dumped => C_Status_Core_Dumped (Raw_Status) /= 0);
      else
         raise Process_Error with "unrecognized subprocess wait status";
      end if;
   end Decode;

   procedure Wait
     (Child   : in out Process;
      Status  : out Exit_Status;
      Timeout : Duration := IO.Infinite;
      Token   : access Cancellation.Token := null)
   is
      Done, Failed           : Boolean;
      Raw_Status, Error_Code : C.int;
   begin
      if not Is_Open (Child) then
         raise Program_Error with "subprocess owner is closed";
      end if;
      Child.Exit_State.Snapshot (Done, Failed, Raw_Status, Error_Code);
      if not Done then
         Wait_Ready (Child.Exit_State.Wait_Descriptor, IO.For_Read, Timeout, Token);
         Child.Exit_State.Snapshot (Done, Failed, Raw_Status, Error_Code);
      end if;
      if not Done then
         raise Process_Error with "subprocess reaper wake lacked a result";
      elsif Failed then
         raise Process_Error with "subprocess reaping failed, error=" & Error_Code'Image;
      end if;
      Status := Decode (Raw_Status);
   exception
      when IO.Device_Error =>
         raise Process_Error with "subprocess exit readiness wait failed";
   end Wait;

   function Native_Signal (Signal : Signal_Kind) return C.int
   is (case Signal is
         when Interrupt            => C_Signal_Interrupt,
         when Graceful_Termination => C_Signal_Terminate,
         when Hard_Kill            => C_Signal_Kill);

   procedure Send_Signal (Child : in out Process; Signal : Signal_Kind) is
      Error_Code : C.int;
   begin
      if not Is_Open (Child) then
         raise Program_Error with "subprocess owner is closed";
      end if;
      Child.Exit_State.Send_Group_Signal (Child.Pid_Value, Native_Signal (Signal), Error_Code);
      if Error_Code /= 0 and then Error_Code /= No_Process_Error then
         raise Process_Error with "subprocess signal failed, errno=" & Error_Code'Image;
      end if;
   end Send_Signal;

   procedure Kill (Child : in out Process) is
   begin
      Send_Signal (Child, Hard_Kill);
   end Kill;

   procedure Stop (Child : in out Process; Grace : Duration; Status : out Exit_Status) is
   begin
      Send_Signal (Child, Graceful_Termination);
      begin
         Wait (Child, Status, Duration'Max (0.0, Grace));
      exception
         when IO.Timeout_Error =>
            Kill (Child);
            Wait (Child, Status);
      end;
   end Stop;

   procedure Release_Process (Child : in out Process) is
   begin
      Close_Standard_Output (Child);
      Close_Standard_Error (Child);
      if Child.Reaper /= null then
         --  Publication precedes task termination. Deallocation must wait for
         --  both, including when the exit readiness wait failed early. A timed
         --  suspension avoids occupying the caller's thread during that join.
         while not Child.Reaper'Terminated loop
            delay 0.01;
         end loop;
         Free_Reaper (Child.Reaper);
      end if;
      Child.Exit_State.Release;
      Free_Exit_State (Child.Exit_State);
      Free_Orphan (Child.Orphan);
      Child.Pid_Value := -1;
   end Release_Process;

   procedure Close (Child : in out Process) is
      Status : Exit_Status;
      Saved  : Ada.Exceptions.Exception_Occurrence;
      Failed : Boolean := False;
   begin
      if not Is_Open (Child) then
         return;
      end if;
      Close_Standard_Input (Child);
      --  A failed signal gives no reason to expect the reaper to finish.
      --  Keep its borrowed exit state and the process owner live for a retry.
      Kill (Child);
      begin
         Wait (Child, Status);
      exception
         when Occurrence : others =>
            Failed := True;
            Ada.Exceptions.Save_Occurrence (Saved, Occurrence);
      end;
      Release_Process (Child);
      if Failed then
         Ada.Exceptions.Reraise_Occurrence (Saved);
      end if;
   end Close;

   overriding
   procedure Finalize (Child : in out Process) is
   begin
      begin
         Close (Child);
      exception
         when others =>
            if Is_Open (Child) then
               Close_Standard_Input (Child);
               Close_Standard_Output (Child);
               Close_Standard_Error (Child);
               --  The preallocated node and heap-backed exit state outlive
               --  this Process. The collector frees both after task exit.
               Child.Orphan.Reaper := Child.Reaper;
               Child.Orphan.State := Child.Exit_State;
               Orphans.Add (Child.Orphan);
               Child.Orphan := null;
               Child.Reaper := null;
               Child.Exit_State := null;
               Child.Pid_Value := -1;
               --  A failed wake cannot give ownership back to Process after
               --  the collector accepted the orphan.
               begin
                  Orphan_Collector.Wake;
               exception
                  when Tasking_Error =>
                     null;
               end;
            end if;
      end;
   end Finalize;

end Flyology.Subprocesses;
