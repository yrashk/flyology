with Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Strings.Unbounded;
with Ada.Streams;
with Flyology;
with Flyology.Cancellation;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.Subprocesses;
with Flyology.Subprocesses.Capture;
with Interfaces.C;

procedure Subprocess_Smoke is
   package Subprocesses renames Flyology.Subprocesses;
   package Capture renames Flyology.Subprocesses.Capture;
   package Sockets renames Flyology.IO.Sockets;
   package C renames Interfaces.C;
   package US renames Ada.Strings.Unbounded;

   use type Ada.Real_Time.Time;
   use type Ada.Real_Time.Time_Span;
   use type Ada.Streams.Stream_Element_Offset;
   use type C.int;
   use type Subprocesses.Exit_Kind;

   Large_Standard_Input : constant String (1 .. 300_000) := (others => 'I');

   function Open_FD_Count return C.int;
   pragma Import (C, Open_FD_Count, "flyology_test_open_fd_count");

   function Pid_Exists (Pid : C.int) return C.int;
   pragma Import (C, Pid_Exists, "flyology_test_subprocess_pid_exists");

   procedure Set_Fail_Reaper_Allocation (Enabled : C.int);
   pragma Import (C, Set_Fail_Reaper_Allocation, "flyology_test_subprocess_set_fail_reaper_allocation");

   procedure Set_Fail_Group_Signal (Enabled : C.int);
   pragma Import (C, Set_Fail_Group_Signal, "flyology_test_subprocess_set_fail_group_signal");

   procedure Arm_Reap_Barrier;
   pragma Import (C, Arm_Reap_Barrier, "flyology_test_subprocess_arm_reap_barrier");
   procedure Await_Reap_Barrier;
   pragma Import (C, Await_Reap_Barrier, "flyology_test_subprocess_await_reap_barrier");
   procedure Release_Reap_Barrier;
   pragma Import (C, Release_Reap_Barrier, "flyology_test_subprocess_release_reap_barrier");
   function Group_Signal_Count return C.int;
   pragma Import (C, Group_Signal_Count, "flyology_test_subprocess_group_signal_count");

   Fixture : constant String :=
     Ada.Directories.Compose
       (Ada.Directories.Containing_Directory (Ada.Directories.Full_Name (Ada.Command_Line.Command_Name)),
        "subprocess_fixture");

   procedure Assert (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Assert;

   function Fixture_Command (Mode : String) return Subprocesses.Command is
      Item : Subprocesses.Command := Subprocesses.To_Command (Fixture);
   begin
      Subprocesses.Append_Argument (Item, Mode);
      return Item;
   end Fixture_Command;

   procedure Exercise_Closed_Standard_Input is
      Child  : Subprocesses.Process;
      Status : Subprocesses.Exit_Status;
      Buffer : constant Ada.Streams.Stream_Element_Array (1 .. 4_096) := (others => 0);
      Last   : Ada.Streams.Stream_Element_Offset;
      Raised : Boolean := False;
   begin
      Subprocesses.Spawn (Subprocesses.To_Command ("/usr/bin/true"), Child);
      Subprocesses.Wait (Child, Status);
      Assert (Subprocesses.Successful (Status), "closed-input child failed");
      begin
         Subprocesses.Write_Standard_Input (Child, Buffer, Last, Timeout => 2.0);
      exception
         when Subprocesses.Pipe_Error =>
            Raised := True;
      end;
      Assert (Raised, "closed child stdin did not raise Pipe_Error");
      Subprocesses.Close (Child);
   end Exercise_Closed_Standard_Input;

   procedure Exercise_Reaped_Group_Signals is
      Child  : Subprocesses.Process;
      Status : Subprocesses.Exit_Status;
      Count  : C.int;
   begin
      Arm_Reap_Barrier;
      Subprocesses.Spawn (Subprocesses.To_Command ("/usr/bin/true"), Child);
      Await_Reap_Barrier;
      --  The root has been reaped, but the public exit result is still pending.
      --  Count attempted group signals without arranging actual PID reuse.
      Subprocesses.Send_Signal (Child, Subprocesses.Graceful_Termination);
      Subprocesses.Kill (Child);
      Count := Group_Signal_Count;
      Release_Reap_Barrier;
      Assert (Count = 0, "reaped process group was signaled before exit publication");
      Subprocesses.Wait (Child, Status);
      Assert (Subprocesses.Successful (Status), "reaped child status changed");
      Subprocesses.Stop (Child, Grace => 0.0, Status => Status);
      Subprocesses.Close (Child);
      Assert (Group_Signal_Count = 0, "Stop or Close signaled a reaped process group");
   exception
      when others =>
         Release_Reap_Barrier;
         raise;
   end Exercise_Reaped_Group_Signals;

   protected Outcome is
      procedure Reset;
      procedure Fail (Message : String);
      procedure Check;
   private
      Failed : Boolean := False;
      Length : Natural := 0;
      Text   : String (1 .. 512) := (others => ' ');
   end Outcome;

   protected body Outcome is
      procedure Reset is
      begin
         Failed := False;
         Length := 0;
      end Reset;

      procedure Fail (Message : String) is
      begin
         Failed := True;
         Length := Natural'Min (Text'Length, Message'Length);
         Text (1 .. Length) := Message (Message'First .. Message'First + Length - 1);
      end Fail;

      procedure Check is
      begin
         if Failed then
            raise Program_Error with Text (1 .. Length);
         end if;
      end Check;
   end Outcome;

   procedure Exercise is
      Value  : Capture.Result;
      Status : Subprocesses.Exit_Status;

      procedure Await_Ready (Child : in out Subprocesses.Process) is
         Buffer : Ada.Streams.Stream_Element_Array (1 .. 5);
         Last   : Ada.Streams.Stream_Element_Offset;
         Text   : String (1 .. 5);
      begin
         Subprocesses.Read_Standard_Output (Child, Buffer, Last, Timeout => 2.0);
         Assert (Last = Buffer'Last, "child readiness message was incomplete");
         for Index in Text'Range loop
            Text (Index) :=
              Character'Val (Buffer (Buffer'First + Ada.Streams.Stream_Element_Offset (Index - 1)));
         end loop;
         Assert (Text = "ready", "child readiness message was invalid");
      end Await_Ready;
   begin
      Exercise_Closed_Standard_Input;
      Exercise_Reaped_Group_Signals;

      Value := Capture.Run (Fixture_Command ("capture"));
      Assert (Subprocesses.Successful (Capture.Status (Value)), "capture child failed");
      Assert (Capture.Standard_Output (Value) = "stdout-value", "stdout capture mismatch");
      Assert (Capture.Standard_Error (Value) = "stderr-value", "stderr capture mismatch");

      Value := Capture.Run (Fixture_Command ("stdin"), Standard_Input => "typed stdin", Maximum_Output => 32);
      Assert (Capture.Standard_Output (Value) = "typed stdin", "stdin round trip mismatch");

      declare
         Item : Subprocesses.Command := Subprocesses.To_Command ("/usr/bin/head");
      begin
         Subprocesses.Append_Argument (Item, "-c");
         Subprocesses.Append_Argument (Item, "10");
         Value :=
           Capture.Run (Item, Standard_Input => Large_Standard_Input, Maximum_Output => 32, Timeout => 10.0);
         Assert (Subprocesses.Successful (Capture.Status (Value)), "prefix-input child failed");
         Assert (Capture.Standard_Output (Value) = Large_Standard_Input (1 .. 10), "prefix output was lost");
      end;

      Value := Capture.Run (Fixture_Command ("nonzero"));
      Assert
        (Capture.Status (Value).Kind = Subprocesses.Exited and then Capture.Status (Value).Code = 23,
         "nonzero exit was not classified");

      declare
         Item : Subprocesses.Command := Subprocesses.To_Command ("true");
      begin
         Subprocesses.Set_Path_Search (Item);
         Value := Capture.Run (Item);
         Assert
           (Subprocesses.Successful (Capture.Status (Value)),
            "PATH search did not find a standard executable");
      end;

      declare
         Missing  : constant Subprocesses.Command := Subprocesses.To_Command ("/flyology/missing/executable");
         Child    : Subprocesses.Process;
         Rejected : Boolean := False;
         Before   : constant C.int := Open_FD_Count;
      begin
         begin
            Subprocesses.Spawn (Missing, Child);
         exception
            when Subprocesses.Spawn_Error =>
               Rejected := True;
         end;
         Assert (Rejected, "missing executable was accepted");
         Assert (Open_FD_Count = Before, "failed spawn leaked descriptors");
      end;

      declare
         Child    : Subprocesses.Process;
         Rejected : Boolean := False;
         Before   : constant C.int := Open_FD_Count;
      begin
         Set_Fail_Reaper_Allocation (1);
         begin
            Subprocesses.Spawn (Fixture_Command ("capture"), Child);
         exception
            when Subprocesses.Spawn_Error =>
               Rejected := True;
            when others =>
               Set_Fail_Reaper_Allocation (0);
               raise;
         end;
         Set_Fail_Reaper_Allocation (0);
         Assert (Rejected, "injected reaper failure was not reported");
         Assert (not Subprocesses.Is_Open (Child), "reaper failure retained subprocess ownership");
         Assert (Open_FD_Count = Before, "reaper failure leaked exit readiness descriptors");
      exception
         when others =>
            Set_Fail_Reaper_Allocation (0);
            raise;
      end;

      declare
         Timed_Out : Boolean := False;
      begin
         begin
            Value := Capture.Run (Fixture_Command ("flood"), Maximum_Output => 32, Timeout => 0.030);
         exception
            when Flyology.IO.Timeout_Error =>
               Timed_Out := True;
         end;
         Assert (Timed_Out, "continuous output starved the capture deadline");
      end;

      declare
         Token     : aliased Flyology.Cancellation.Token;
         task Canceller;
         task body Canceller is
         begin
            delay 0.030;
            Token.Request;
         end Canceller;
         Cancelled : Boolean := False;
      begin
         begin
            Value :=
              Capture.Run
                (Fixture_Command ("flood"), Maximum_Output => 32, Timeout => 2.0, Token => Token'Access);
         exception
            when Flyology.Cancellation.Operation_Cancelled =>
               Cancelled := True;
         end;
         Assert (Cancelled, "continuous output starved capture cancellation");
      end;

      Value :=
        Capture.Run
          (Fixture_Command ("output-before-input"),
           Standard_Input => "I",
           Maximum_Output => 32,
           Maximum_Error  => 32,
           Timeout        => 2.0);
      Assert (Capture.Standard_Error (Value) = "I", "continuous stdout starved writable stdin");

      declare
         Timed_Out : Boolean := False;
         Started   : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      begin
         begin
            Value := Capture.Run (Fixture_Command ("escaped-pipe-holder"), Timeout => 0.030);
         exception
            when Flyology.IO.Timeout_Error =>
               Timed_Out := True;
         end;
         Assert (Timed_Out, "escaped pipe holder suppressed timeout");
         Assert
           (Ada.Real_Time.Clock - Started < Ada.Real_Time.Seconds (1),
            "escaped pipe holder delayed exceptional cleanup");
      end;

      Value :=
        Capture.Run
          (Fixture_Command ("large"), Maximum_Output => 1_000, Maximum_Error => 777, Timeout => 10.0);
      Assert (Subprocesses.Successful (Capture.Status (Value)), "large-output child failed");
      Assert
        (Capture.Standard_Output (Value)'Length = 1_000
         and then Capture.Standard_Error (Value)'Length = 777
         and then Capture.Output_Truncated (Value)
         and then Capture.Error_Truncated (Value),
         "bounded capture did not truncate while draining");

      declare
         Item : Subprocesses.Command := Fixture_Command ("env");
      begin
         Subprocesses.Clear_Environment (Item);
         Subprocesses.Set_Environment_Variable (Item, "FLYOLOGY_CHILD_VALUE", "explicit-value");
         Value := Capture.Run (Item);
         Assert (Capture.Standard_Output (Value) = "explicit-value", "explicit child environment mismatch");
      end;

      declare
         Item      : Subprocesses.Command := Fixture_Command ("cwd");
         Directory : constant String := Ada.Directories.Containing_Directory (Fixture);
      begin
         Subprocesses.Set_Working_Directory (Item, Directory);
         Value := Capture.Run (Item);
         Assert (Capture.Standard_Output (Value) = Directory, "child working directory mismatch");
      end;

      declare
         Child  : Subprocesses.Process;
         Before : constant C.int := Open_FD_Count;
      begin
         Subprocesses.Spawn (Fixture_Command ("graceful"), Child);
         Await_Ready (Child);
         Subprocesses.Stop (Child, Grace => 1.0, Status => Status);
         Assert (Subprocesses.Successful (Status), "graceful stop did not permit clean exit");
         Subprocesses.Close (Child);
         Assert (Open_FD_Count = Before, "Close retained subprocess descriptors before finalization");
      end;

      declare
         Child     : Subprocesses.Process;
         Timed_Out : Boolean := False;
      begin
         Subprocesses.Spawn (Fixture_Command ("resistant"), Child);
         Await_Ready (Child);
         Subprocesses.Send_Signal (Child, Subprocesses.Graceful_Termination);
         begin
            Subprocesses.Wait (Child, Status, Timeout => 0.030);
         exception
            when Flyology.IO.Timeout_Error =>
               Timed_Out := True;
         end;
         Assert (Timed_Out, "signal-resistant child stopped gracefully");
         Subprocesses.Kill (Child);
         Subprocesses.Wait (Child, Status);
         Assert
           (Status.Kind = Subprocesses.Signaled and then Status.Signal > 0,
            "hard stop was not signal-classified");
         Subprocesses.Close (Child);
      end;

      declare
         Child   : Subprocesses.Process;
         Before  : constant C.int := Open_FD_Count;
         Raised  : Boolean := False;
         Started : Ada.Real_Time.Time;
      begin
         Subprocesses.Spawn (Fixture_Command ("resistant"), Child);
         Await_Ready (Child);
         Set_Fail_Group_Signal (1);
         Started := Ada.Real_Time.Clock;
         begin
            Subprocesses.Close (Child);
         exception
            when Subprocesses.Process_Error =>
               Raised := True;
         end;
         Set_Fail_Group_Signal (0);
         Assert (Raised, "Close did not report a failed hard kill");
         Assert (Subprocesses.Is_Open (Child), "failed Close discarded a live reaper owner");
         Assert
           (Ada.Real_Time.Clock - Started < Ada.Real_Time.Seconds (1),
            "failed Close waited for a still-running child");
         Subprocesses.Close (Child);
         Assert (not Subprocesses.Is_Open (Child), "Close retry retained process ownership");
         Assert (Open_FD_Count = Before, "Close retry leaked process descriptors");
      exception
         when others =>
            Set_Fail_Group_Signal (0);
            raise;
      end;

      declare
         Before  : constant C.int := Open_FD_Count;
         Started : Ada.Real_Time.Time;
      begin
         declare
            Child : Subprocesses.Process;
         begin
            Subprocesses.Spawn (Fixture_Command ("short-sleep"), Child);
            Await_Ready (Child);
            Set_Fail_Group_Signal (1);
            Started := Ada.Real_Time.Clock;
         end;
         Set_Fail_Group_Signal (0);
         Assert
           (Ada.Real_Time.Clock - Started < Ada.Real_Time.Milliseconds (250),
            "failed-kill finalization waited for natural exit");
         for Attempt in 1 .. 200 loop
            exit when Open_FD_Count = Before;
            delay 0.01;
         end loop;
         Assert (Open_FD_Count = Before, "orphan reaper retained exit readiness descriptors");
      exception
         when others =>
            Set_Fail_Group_Signal (0);
            raise;
      end;

      declare
         Started    : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
         Descendant : C.int;
      begin
         Value := Capture.Run (Fixture_Command ("descendant"), Timeout => 2.0);
         Descendant := C.int'Value (Capture.Standard_Output (Value));
         Assert
           (Ada.Real_Time.Clock - Started < Ada.Real_Time.Seconds (2), "descendant retained capture pipes");
         for Attempt in 1 .. 100 loop
            exit when Pid_Exists (Descendant) = 0;
            delay 0.001;
         end loop;
         Assert (Pid_Exists (Descendant) = 0, "process-group descendant escaped cleanup");
      end;
   end Exercise;

   task type Runner (Model : Flyology.Execution_Model) is
      pragma Task_Info (Model);
   end Runner;

   task body Runner is
   begin
      Exercise;
   exception
      when Occurrence : others =>
         Outcome.Fail (Ada.Exceptions.Exception_Information (Occurrence));
   end Runner;

   procedure Run_Model (Model : Flyology.Execution_Model) is
   begin
      Outcome.Reset;
      declare
         Item : Runner (Model);
      begin
         null;
      end;
      Outcome.Check;
   end Run_Model;

   protected Parallel_Outcome is
      procedure Complete;
      procedure Fail;
      procedure Check;
   private
      Completed : Natural := 0;
      Failed    : Boolean := False;
   end Parallel_Outcome;

   protected body Parallel_Outcome is
      procedure Complete is
      begin
         Completed := Completed + 1;
      end Complete;

      procedure Fail is
      begin
         Failed := True;
      end Fail;

      procedure Check is
      begin
         Assert (not Failed and then Completed = 4, "concurrent independent subprocesses failed");
      end Check;
   end Parallel_Outcome;

   task type Parallel_Runner (Index : Positive) is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Parallel_Runner;

   task body Parallel_Runner is
      pragma Unreferenced (Index);
      Value : Capture.Result;
   begin
      Value := Capture.Run (Fixture_Command ("capture"), Timeout => 2.0);
      if Subprocesses.Successful (Capture.Status (Value))
        and then Capture.Standard_Output (Value) = "stdout-value"
      then
         Parallel_Outcome.Complete;
      else
         Parallel_Outcome.Fail;
      end if;
   exception
      when others =>
         Parallel_Outcome.Fail;
   end Parallel_Runner;

   Race_Baseline : US.Unbounded_String;

   protected Race_Outcome is
      procedure Complete;
      procedure Fail (Message : String);
      function Stopped return Boolean;
      procedure Check;
   private
      Completed : Natural := 0;
      Length    : Natural := 0;
      Text      : String (1 .. 128) := (others => ' ');
   end Race_Outcome;

   protected body Race_Outcome is
      procedure Complete is
      begin
         Completed := Completed + 1;
      end Complete;

      procedure Fail (Message : String) is
      begin
         if Length = 0 then
            Length := Natural'Min (Text'Length, Message'Length);
            Text (1 .. Length) := Message (Message'First .. Message'First + Length - 1);
         end if;
      end Fail;

      function Stopped return Boolean is
      begin
         return Completed = 4;
      end Stopped;

      procedure Check is
      begin
         Assert (Completed = 4, "descriptor race spawners did not complete");
         if Length > 0 then
            raise Program_Error with Text (1 .. Length);
         end if;
      end Check;
   end Race_Outcome;

   task type Race_Spawner is
      pragma Task_Info (Flyology.Native_Task);
   end Race_Spawner;

   task body Race_Spawner is
   begin
      for Iteration in 1 .. 60 loop
         declare
            Value : constant Capture.Result :=
              Capture.Run (Fixture_Command ("inspect-descriptors"), Maximum_Output => 4_096, Timeout => 5.0);
         begin
            if not Subprocesses.Successful (Capture.Status (Value))
              or else Capture.Standard_Output (Value) /= US.To_String (Race_Baseline)
            then
               Race_Outcome.Fail ("spawn inherited unrelated descriptor: " & Capture.Standard_Output (Value));
            end if;
         end;
      end loop;
      Race_Outcome.Complete;
   exception
      when others =>
         Race_Outcome.Fail ("descriptor race spawn failed");
         Race_Outcome.Complete;
   end Race_Spawner;

   task type Race_Churn is
      pragma Task_Info (Flyology.Native_Task);
   end Race_Churn;

   task body Race_Churn is
      Left, Right : Sockets.Socket_Type;
   begin
      while not Race_Outcome.Stopped loop
         Sockets.Create_Socket_Pair (Left, Right);
         Sockets.Close_Socket (Left);
         Sockets.Close_Socket (Right);
      end loop;
   exception
      when others =>
         Race_Outcome.Fail ("descriptor race socket-pair churn failed");
   end Race_Churn;

   Before, After : C.int;
begin
   Run_Model (Flyology.Lightweight_Task);
   Run_Model (Flyology.Native_Task);

   declare
      First  : Parallel_Runner (1);
      Second : Parallel_Runner (2);
      Third  : Parallel_Runner (3);
      Fourth : Parallel_Runner (4);
   begin
      null;
   end;
   Parallel_Outcome.Check;

   declare
      Baseline : constant Capture.Result :=
        Capture.Run (Fixture_Command ("inspect-descriptors"), Maximum_Output => 4_096, Timeout => 5.0);
   begin
      Assert (Subprocesses.Successful (Capture.Status (Baseline)), "descriptor baseline child failed");
      Race_Baseline := US.To_Unbounded_String (Capture.Standard_Output (Baseline));
      declare
         First  : Race_Spawner;
         Second : Race_Spawner;
         Third  : Race_Spawner;
         Fourth : Race_Spawner;
         Churn  : Race_Churn;
      begin
         null;
      end;
   end;
   Race_Outcome.Check;

   Before := Open_FD_Count;
   for Iteration in 1 .. 25 loop
      declare
         Value : constant Capture.Result := Capture.Run (Fixture_Command ("capture"));
      begin
         Assert (Subprocesses.Successful (Capture.Status (Value)), "repeated spawn failed");
      end;
   end loop;
   After := Open_FD_Count;
   Assert (After = Before, "subprocess operations leaked descriptors");
end Subprocess_Smoke;
