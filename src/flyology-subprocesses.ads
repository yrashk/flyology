with Ada.Finalization;
with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;
with Ada.Streams;
with Flyology.Cancellation;
with Flyology.IO;
with Flyology.Wake_Sources;
with Interfaces.C;

--  Spawns and owns native subprocesses without invoking a command shell.
--  Spawn uses posix_spawn(3), which is safe after Ada tasking and Flyology
--  event loops have started. Every child starts in a new process group. The
--  owner reaps the root process and removes remaining members of that group;
--  a child that deliberately leaves that group, for example with setpgid(2)
--  or setsid(2), is outside that boundary.
--
--  Standard streams are nonblocking in the parent and blocking in the child.
--  Lightweight callers suspend on pipe or exit readiness; native callers
--  block only their pthread. Spawn itself is a synchronous metadata operation
--  and can occupy a lightweight caller's event-loop pthread. Use a native-task
--  boundary when spawn latency is not acceptable there.
--
--  Process must outlive every operation on it. At most one operation may be
--  active on each standard stream. Different streams may progress
--  concurrently. Serialize Close, finalization, and each explicit stream
--  close against every operation that can use the affected descriptor.

package Flyology.Subprocesses is

   use type Interfaces.C.int;

   --  Raised when a command cannot be spawned.
   Spawn_Error   : exception;
   --  Raised when process observation or signaling fails.
   Process_Error : exception;
   --  Raised when a standard-stream operation fails.
   Pipe_Error    : exception;

   --  Description of an executable and its launch environment. A command is
   --  a value and may be copied before Spawn. Arguments remain separate string
   --  values and are never interpreted by a shell.
   type Command is private;

   --  Construct a command with no arguments, inherited environment, inherited
   --  working directory, and no PATH search.
   --  @param Executable Executable path or name
   --  @return New command description
   --  @exception Constraint_Error Executable is empty or contains NUL
   function To_Command (Executable : String) return Command;

   --  Append one argv value after argv[0]. Empty arguments are retained.
   --  @param Item Command to update
   --  @param Value Exact argument bytes
   --  @exception Constraint_Error Value contains NUL
   procedure Append_Argument (Item : in out Command; Value : String);

   --  Remove every argument while retaining the executable and launch policy.
   --  @param Item Command to update
   procedure Clear_Arguments (Item : in out Command);

   --  Select whether Spawn searches the caller's PATH for Executable. PATH
   --  lookup uses the parent environment even when an explicit child
   --  environment is configured.
   --  @param Item Command to update
   --  @param Enabled True to use posix_spawnp; False to use posix_spawn
   procedure Set_Path_Search (Item : in out Command; Enabled : Boolean := True);

   --  Set the child working directory. Darwin and glibc Linux implement this
   --  through posix_spawn file actions; an unavailable host extension causes
   --  Spawn_Error rather than a fork fallback.
   --  @param Item Command to update
   --  @param Directory Directory entered before exec
   --  @exception Constraint_Error Directory is empty or contains NUL
   procedure Set_Working_Directory (Item : in out Command; Directory : String);

   --  Restore inherited working-directory behavior.
   --  @param Item Command to update
   procedure Inherit_Working_Directory (Item : in out Command);

   --  Replace inherited environment behavior with an explicit empty
   --  environment. Add variables with Set_Environment_Variable.
   --  @param Item Command to update
   procedure Clear_Environment (Item : in out Command);

   --  Restore complete environment inheritance from the parent process.
   --  @param Item Command to update
   procedure Inherit_Environment (Item : in out Command);

   --  Add or replace one variable in the explicit child environment. Calling
   --  this operation changes inherited mode to an explicit environment
   --  containing only variables set on Item.
   --  @param Item Command to update
   --  @param Name Nonempty variable name without '=' or NUL
   --  @param Value Variable value without NUL
   --  @exception Constraint_Error Name or Value is invalid
   procedure Set_Environment_Variable (Item : in out Command; Name, Value : String);

   --  Operating-system process identifier used for launch-time diagnostics.
   --  After the root is reaped, the host may reuse its value even while the
   --  corresponding Process owner remains open.
   subtype Process_Id is Interfaces.C.int range 1 .. Interfaces.C.int'Last;

   --  Classification of a reaped root process.
   --  @enum Exited The process called exit or returned from its main routine
   --  @enum Signaled The process terminated because of a signal
   type Exit_Kind is (Exited, Signaled);

   --  Portable child termination result.
   --  @field Kind Exit or signal classification
   --  @field Code Exit code when Kind is Exited; otherwise zero
   --  @field Signal Signal number when Kind is Signaled; otherwise zero
   --  @field Core_Dumped True when the host reports a core-producing signal
   type Exit_Status is record
      Kind        : Exit_Kind := Exited;
      Code        : Natural range 0 .. 255 := 0;
      Signal      : Natural := 0;
      Core_Dumped : Boolean := False;
   end record;

   --  Report whether Status is an ordinary zero exit.
   --  @param Status Reaped child result
   --  @return True only for Exited with code zero
   function Successful (Status : Exit_Status) return Boolean
   is (Status.Kind = Exited and then Status.Code = 0);

   --  Signals exposed by the portable process-group API.
   --  @enum Interrupt Interrupt request, normally SIGINT
   --  @enum Graceful_Termination Graceful request, normally SIGTERM
   --  @enum Hard_Kill Uncatchable hard termination, normally SIGKILL
   type Signal_Kind is (Interrupt, Graceful_Termination, Hard_Kill);

   --  Limited owner of one root process, its process group, its three parent
   --  pipe ends, and its reaper. Finalization closes stdin, hard-terminates an
   --  unjoined group, waits for root reaping, and closes stdout and stderr.
   --  At most one operation may be active on each standard stream. Operations
   --  on distinct streams may run concurrently. Serialize every explicit
   --  stream close and owner finalization against all active operations.
   --  Declare owners at a structured scope. If hard termination fails during
   --  finalization, the reaper retains its own exit state until natural exit.
   --  A successful hard termination can still wait for a kernel task stuck in
   --  an uninterruptible state.
   type Process is new Ada.Finalization.Limited_Controlled with private;

   --  Spawn Command and transfer the parent ends of stdin, stdout, and stderr
   --  into Child. On Darwin, Spawn closes all other descriptors in the child,
   --  including application descriptors without FD_CLOEXEC; only standard
   --  streams and explicitly transferred bootstrap descriptors are inherited.
   --  On Linux, descriptors follow their FD_CLOEXEC policy; Flyology-created
   --  descriptors are atomically close-on-exec. Spawn synchronously resets the
   --  child's signal mask to empty and every catchable signal disposition to
   --  its default before exec. It has no
   --  deadline or cancellation parameter. A failed call leaves Child empty and
   --  retains no process or descriptor ownership.
   --  @param Item Typed executable, argv, environment, and directory policy
   --  @param Child Empty owner that receives the process and pipes
   --  @exception Spawn_Error Pipe setup, process attributes, exec, or reaper
   --     allocation fails
   --  @exception Program_Error Child already owns a process
   --  @exception Storage_Error Launch-description allocation fails
   procedure Spawn (Item : Command; Child : in out Process);

   --  Report whether Child owns a spawned process that has not been closed.
   --  A reaped process remains owned until Close releases its pipes and
   --  reaper.
   --  @param Child Process owner to inspect
   --  @return True between successful Spawn and Close
   function Is_Open (Child : Process) return Boolean;

   --  Report whether the reaper has observed terminal process state. This is a
   --  nonblocking observation; the status remains available to Wait.
   --  @param Child Open process owner
   --  @return True after exit or a terminal reaper failure is recorded
   --  @exception Program_Error Child is closed
   function Has_Exited (Child : Process) return Boolean;

   --  Return the root's launch-time process identifier. After reaping, the
   --  host may reuse this value even before Child is closed. Do not use it for
   --  signaling or as a durable application identity.
   --  @param Child Open process owner
   --  @return Root process identifier
   --  @exception Program_Error Child is closed
   function Identifier (Child : Process) return Process_Id;

   --  Report whether the writable parent end of child stdin remains open.
   --  @param Child Process owner to inspect
   --  @return True when stdin can still be written
   function Standard_Input_Is_Open (Child : Process) return Boolean;

   --  Report whether the readable parent end of child stdout remains open.
   --  @param Child Process owner to inspect
   --  @return True when stdout can still be read
   function Standard_Output_Is_Open (Child : Process) return Boolean;

   --  Report whether the readable parent end of child stderr remains open.
   --  @param Child Process owner to inspect
   --  @return True when stderr can still be read
   function Standard_Error_Is_Open (Child : Process) return Boolean;

   --  Close child stdin. Repeated calls are harmless and the child observes
   --  end-of-file after buffered pipe data is consumed.
   --  @param Child Process owner
   procedure Close_Standard_Input (Child : in out Process);

   --  Close child stdout without consuming remaining bytes. Repeated calls
   --  are harmless.
   --  @param Child Process owner
   procedure Close_Standard_Output (Child : in out Process);

   --  Close child stderr without consuming remaining bytes. Repeated calls
   --  are harmless.
   --  @param Child Process owner
   procedure Close_Standard_Error (Child : in out Process);

   --  Read one available stdout chunk. Last precedes Item'First on EOF or for
   --  an empty Item. One monotonic deadline covers readiness retries.
   --  @param Child Process owner
   --  @param Item Destination bytes
   --  @param Last Last byte read, or Item'First - 1
   --  @param Timeout Deadline interval in seconds; negative means unlimited
   --  @param Token Optional cancellation source that must outlive the call
   --  @exception Timeout_Error The deadline expires
   --  @exception Operation_Cancelled Token is requested
   --  @exception Pipe_Error Read or descriptor state fails
   procedure Read_Standard_Output
     (Child   : in out Process;
      Item    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration := Flyology.IO.Infinite;
      Token   : access Flyology.Cancellation.Token := null);

   --  Read one available stderr chunk with the same semantics as
   --  Read_Standard_Output.
   --  @param Child Process owner
   --  @param Item Destination bytes
   --  @param Last Last byte read, or Item'First - 1
   --  @param Timeout Deadline interval in seconds; negative means unlimited
   --  @param Token Optional cancellation source that must outlive the call
   --  @exception Timeout_Error The deadline expires
   --  @exception Operation_Cancelled Token is requested
   --  @exception Pipe_Error Read or descriptor state fails
   procedure Read_Standard_Error
     (Child   : in out Process;
      Item    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration := Flyology.IO.Infinite;
      Token   : access Flyology.Cancellation.Token := null);

   --  Write one available stdin chunk. Last precedes Item'First only for an
   --  empty Item. A closed child read end raises Pipe_Error without delivering
   --  SIGPIPE to the calling native or event-loop pthread.
   --  @param Child Process owner
   --  @param Item Source bytes
   --  @param Last Last byte written, or Item'First - 1
   --  @param Timeout Deadline interval in seconds; negative means unlimited
   --  @param Token Optional cancellation source that must outlive the call
   --  @exception Timeout_Error The deadline expires
   --  @exception Operation_Cancelled Token is requested
   --  @exception Pipe_Error Write or descriptor state fails
   procedure Write_Standard_Input
     (Child   : in out Process;
      Item    : Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration := Flyology.IO.Infinite;
      Token   : access Flyology.Cancellation.Token := null);

   --  Wait for and reap the root process. Remaining members of its original
   --  process group are hard-terminated before the status becomes ready. The
   --  result is stable and subsequent Wait calls return it immediately.
   --  @param Child Process owner
   --  @param Status Root process termination result
   --  @param Timeout Deadline interval in seconds; negative means unlimited
   --  @param Token Optional cancellation source that must outlive the call
   --  @exception Timeout_Error The deadline expires
   --  @exception Operation_Cancelled Token is requested
   --  @exception Process_Error Process observation fails
   --  @exception Program_Error Child is closed
   procedure Wait
     (Child   : in out Process;
      Status  : out Exit_Status;
      Timeout : Duration := Flyology.IO.Infinite;
      Token   : access Flyology.Cancellation.Token := null);

   --  Send one signal to the root process's original process group. A group
   --  already gone is treated as success. This operation does not wait.
   --  @param Child Open process owner
   --  @param Signal Signal to send
   --  @exception Process_Error kill(2) fails for a live group
   --  @exception Program_Error Child is closed
   procedure Send_Signal (Child : in out Process; Signal : Signal_Kind);

   --  Send the hard termination signal to the owned process group without
   --  waiting. Reaping remains the owner's responsibility through Wait or
   --  Close.
   --  @param Child Open process owner
   --  @exception Process_Error kill(2) fails for a live group
   --  @exception Program_Error Child is closed
   procedure Kill (Child : in out Process);

   --  Request graceful group termination and wait up to Grace seconds for the
   --  root. A nonpositive Grace permits only an immediate observation attempt.
   --  If the root is still running after that interval, hard-terminate the
   --  group. If the root exits sooner, the reaper immediately hard-terminates
   --  remaining members of its original group. The root is always reaped
   --  before return. Pipes stay open for explicit draining or Close.
   --  @param Child Open process owner
   --  @param Grace Monotonic graceful-stop interval in seconds
   --  @param Status Root process termination result
   --  @exception Process_Error Signaling or process observation fails
   --  @exception Program_Error Child is closed
   procedure Stop (Child : in out Process; Grace : Duration; Status : out Exit_Status);

   --  End ownership. Close first closes stdin, hard-terminates a running
   --  group, reaps the root, closes output pipes, and joins the native reaper.
   --  If hard termination fails, Close raises promptly and retains the open
   --  process owner and reaper so the caller can retry after the failure is
   --  resolved. Repeated successful calls are harmless. If finalization cannot
   --  hard-terminate the group, it closes the pipes and leaves the reaper to
   --  finish independently after natural root exit.
   --  @param Child Process owner to release
   --  @exception Process_Error Process cleanup or observation fails
   procedure Close (Child : in out Process);

private
   package String_Vectors is new
     Ada.Containers.Indefinite_Vectors (Index_Type => Positive, Element_Type => String);

   type Environment_Entry is record
      Name  : Ada.Strings.Unbounded.Unbounded_String;
      Value : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Environment_Vectors is new
     Ada.Containers.Indefinite_Vectors (Index_Type => Positive, Element_Type => Environment_Entry);

   type Command is record
      Executable           : Ada.Strings.Unbounded.Unbounded_String;
      Arguments            : String_Vectors.Vector;
      Environment          : Environment_Vectors.Vector;
      Explicit_Environment : Boolean := False;
      Working_Directory    : Ada.Strings.Unbounded.Unbounded_String;
      Has_Directory        : Boolean := False;
      Search_Path          : Boolean := False;
   end record;

   protected type Exit_Control is
      procedure Prepare;
      procedure Release;
      procedure Mark_Exit_Observed;
      procedure Send_Group_Signal (Pid, Signal : Interfaces.C.int; Error_Code : out Interfaces.C.int);
      procedure Complete (Raw_Status, Error_Code : Interfaces.C.int);
      procedure Snapshot (Done, Failed : out Boolean; Raw_Status, Error_Code : out Interfaces.C.int);
      function Completed return Boolean;
      function Wait_Descriptor return Flyology.IO.Descriptor;
   private
      Is_Done       : Boolean := False;
      Exit_Observed : Boolean := False;
      Has_Failed    : Boolean := False;
      Status_Value  : Interfaces.C.int := 0;
      Error_Value   : Interfaces.C.int := 0;
      Wake          : Flyology.Wake_Sources.Source;
   end Exit_Control;
   type Exit_Control_Access is access all Exit_Control;

   task type Reaper_Task
     (Pid   : Interfaces.C.int;
      State : Exit_Control_Access)
   is
      pragma Task_Info (Flyology.Native_Task);
   end Reaper_Task;
   type Reaper_Access is access Reaper_Task;

   type Orphan_Node;
   type Orphan_Access is access Orphan_Node;
   type Orphan_Node is record
      Reaper : Reaper_Access := null;
      State  : Exit_Control_Access := null;
      Next   : Orphan_Access := null;
   end record;

   type Process is new Ada.Finalization.Limited_Controlled with record
      Pid_Value  : Interfaces.C.int := -1;
      Input_FD   : Flyology.IO.Descriptor := Flyology.IO.Invalid_Descriptor;
      Output_FD  : Flyology.IO.Descriptor := Flyology.IO.Invalid_Descriptor;
      Error_FD   : Flyology.IO.Descriptor := Flyology.IO.Invalid_Descriptor;
      Exit_State : Exit_Control_Access := null;
      Reaper     : Reaper_Access := null;
      Orphan     : Orphan_Access := null;
   end record;

   --  Internal write seam used by the Capture child package. Reader_Closed
   --  reports EPIPE separately; every other low-level failure retains the
   --  public Write_Standard_Input exception contract.
   --  @exclude
   --  @param Child Running subprocess whose standard input is written
   --  @param Item Bytes to write
   --  @param Last Index of the last byte written, or before Item'First when none
   --  @param Reader_Closed Whether the child closed its input before this write
   --  @param Timeout Maximum wait for writable readiness
   --  @param Token Optional cancellation token
   procedure Try_Write_Standard_Input
     (Child         : in out Process;
      Item          : Ada.Streams.Stream_Element_Array;
      Last          : out Ada.Streams.Stream_Element_Offset;
      Reader_Closed : out Boolean;
      Timeout       : Duration := Flyology.IO.Infinite;
      Token         : access Flyology.Cancellation.Token := null);

   --  Internal launch seam used by the Bootstrap child package. Bootstrap
   --  descriptors are either four distinct values above fd 4 or all invalid.
   --  @exclude
   --  @param Item Launch command
   --  @param Child Destination process owner
   --  @param Control_Parent Coordinator control endpoint
   --  @param Control_Child Child control endpoint
   --  @param Capability_Parent Coordinator capability endpoint
   --  @param Capability_Child Child capability endpoint
   --  @param Pipe_Output Create a coordinator-owned standard-output pipe
   --  @param Pipe_Error Create a coordinator-owned standard-error pipe
   procedure Spawn_Internal
     (Item              : Command;
      Child             : in out Process;
      Control_Parent    : Interfaces.C.int;
      Control_Child     : Interfaces.C.int;
      Capability_Parent : Interfaces.C.int;
      Capability_Child  : Interfaces.C.int;
      Pipe_Output       : Boolean := True;
      Pipe_Error        : Boolean := True);

   --  Release process ownership without propagating cleanup failures.
   --  @param Child Process owner being finalized
   overriding
   procedure Finalize (Child : in out Process);

end Flyology.Subprocesses;
