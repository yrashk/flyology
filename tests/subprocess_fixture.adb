with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams;
with Flyology.IO.Socket_Handoffs;
with Flyology.IO.Sockets;
with Flyology.Subprocesses.Bootstrap;
with Interfaces.C;
with System;

procedure Subprocess_Fixture is
   package C renames Interfaces.C;
   package Bootstrap renames Flyology.Subprocesses.Bootstrap;
   package Handoffs renames Flyology.IO.Socket_Handoffs;
   package Sockets renames Flyology.IO.Sockets;

   use type Ada.Streams.Stream_Element_Array;
   use type C.int;
   use type C.long;

   function Read (Descriptor : C.int; Buffer : System.Address; Length : C.size_t) return C.long;
   pragma Import (C, Read, "read");

   function Write (Descriptor : C.int; Buffer : System.Address; Length : C.size_t) return C.long;
   pragma Import (C, Write, "write");

   function Install_Term_Handler return C.int;
   pragma Import (C, Install_Term_Handler, "flyology_test_subprocess_install_term_handler");

   function Term_Requested return C.int;
   pragma Import (C, Term_Requested, "flyology_test_subprocess_term_requested");

   function Ignore_Term return C.int;
   pragma Import (C, Ignore_Term, "flyology_test_subprocess_ignore_term");

   function Fork_Descendant return C.int;
   pragma Import (C, Fork_Descendant, "flyology_test_subprocess_fork_descendant");

   function Fork_Output_Writer return C.int;
   pragma Import (C, Fork_Output_Writer, "flyology_test_subprocess_fork_output_writer");

   function Fork_Escaped_Pipe_Holder return C.int;
   pragma Import (C, Fork_Escaped_Pipe_Holder, "flyology_test_subprocess_fork_escaped_pipe_holder");

   function Descriptor_List (Buffer : System.Address; Capacity : C.size_t) return C.int;
   pragma Import (C, Descriptor_List, "flyology_test_subprocess_descriptor_list");

   procedure Write_All (Descriptor : C.int; Text : String) is
      Offset : Natural := 0;
      Result : C.long;
   begin
      while Offset < Text'Length loop
         Result := Write (Descriptor, Text (Text'First + Offset)'Address, C.size_t (Text'Length - Offset));
         if Result <= 0 then
            Ada.Command_Line.Set_Exit_Status (91);
            return;
         end if;
         Offset := Offset + Natural (Result);
      end loop;
   end Write_All;

   Mode : constant String :=
     (if Ada.Command_Line.Argument_Count = 0 then "none" else Ada.Command_Line.Argument (1));
begin
   if Mode = "bootstrap" then
      declare
         Control      : Sockets.Socket_Type;
         Capabilities : Handoffs.Handoff_Channel;
         Listener     : Sockets.Socket_Type;
         Accepted     : Sockets.Socket_Type;
         Peer         : Sockets.Endpoint;
         Command      : Ada.Streams.Stream_Element_Array (1 .. 1);
         Request      : Ada.Streams.Stream_Element_Array (1 .. 1);
      begin
         Bootstrap.Adopt_Inherited (Control, Capabilities);
         Sockets.Receive_Exactly (Control, Command, Timeout => 2.0);
         if Command /= [1 => 16#42#] then
            Ada.Command_Line.Set_Exit_Status (99);
            return;
         end if;
         Handoffs.Receive_Listener (Capabilities, Listener);
         Sockets.Accept_Connection (Listener, Accepted, Peer, Timeout => 2.0);
         Sockets.Receive_Exactly (Accepted, Request, Timeout => 2.0);
         if Request /= [1 => 16#58#] then
            Ada.Command_Line.Set_Exit_Status (100);
            return;
         end if;
         Sockets.Send_All (Accepted, [1 => 16#59#], Timeout => 2.0);
         Sockets.Send_All (Control, [1 => 16#41#], Timeout => 2.0);
      exception
         when others =>
            Ada.Command_Line.Set_Exit_Status (101);
      end;
   elsif Mode = "capture" then
      Write_All (1, "stdout-value");
      Write_All (2, "stderr-value");
   elsif Mode = "inspect-descriptors" then
      declare
         Buffer : aliased String (1 .. 4_096);
         Length : constant C.int := Descriptor_List (Buffer'Address, Buffer'Length);
      begin
         if Length < 0 then
            Ada.Command_Line.Set_Exit_Status (92);
         else
            Write_All (1, Buffer (1 .. Natural (Length)));
         end if;
      end;
   elsif Mode = "stdin" then
      declare
         Buffer : aliased String (1 .. 4_096);
         Count  : C.long;
      begin
         loop
            Count := Read (0, Buffer'Address, Buffer'Length);
            exit when Count = 0;
            if Count < 0 then
               Ada.Command_Line.Set_Exit_Status (92);
               exit;
            end if;
            Write_All (1, Buffer (1 .. Natural (Count)));
         end loop;
      end;
   elsif Mode = "nonzero" then
      Ada.Command_Line.Set_Exit_Status (23);
   elsif Mode = "sleep" then
      delay 60.0;
   elsif Mode = "short-sleep" then
      Write_All (1, "ready");
      delay 0.5;
   elsif Mode = "large" then
      declare
         Output_Chunk : constant String (1 .. 4_096) := (others => 'O');
         Error_Chunk  : constant String (1 .. 4_096) := (others => 'E');
      begin
         for Iteration in 1 .. 256 loop
            Write_All (1, Output_Chunk);
            Write_All (2, Error_Chunk);
         end loop;
      end;
   elsif Mode = "flood" then
      declare
         Output_Chunk : constant String (1 .. 4_096) := (others => 'F');
      begin
         loop
            Write_All (1, Output_Chunk);
         end loop;
      end;
   elsif Mode = "output-before-input" then
      if Fork_Output_Writer < 0 then
         Ada.Command_Line.Set_Exit_Status (96);
      else
         declare
            Value : aliased Character;
         begin
            if Read (0, Value'Address, 1) = 1 then
               Write_All (2, String'(1 => Value));
            else
               Ada.Command_Line.Set_Exit_Status (97);
            end if;
         end;
      end if;
   elsif Mode = "escaped-pipe-holder" then
      if Fork_Escaped_Pipe_Holder < 0 then
         Ada.Command_Line.Set_Exit_Status (98);
      else
         delay 60.0;
      end if;
   elsif Mode = "graceful" then
      if Install_Term_Handler /= 0 then
         Ada.Command_Line.Set_Exit_Status (93);
      else
         Write_All (1, "ready");
         while Term_Requested = 0 loop
            delay 0.005;
         end loop;
         Write_All (1, "graceful-stop");
      end if;
   elsif Mode = "resistant" then
      if Ignore_Term /= 0 then
         Ada.Command_Line.Set_Exit_Status (94);
      else
         Write_All (1, "ready");
         delay 60.0;
      end if;
   elsif Mode = "cwd" then
      Write_All (1, Ada.Directories.Current_Directory);
   elsif Mode = "env" then
      Write_All (1, Ada.Environment_Variables.Value ("FLYOLOGY_CHILD_VALUE", "missing"));
   elsif Mode = "descendant" then
      declare
         Descendant : constant C.int := Fork_Descendant;
      begin
         if Descendant < 0 then
            Ada.Command_Line.Set_Exit_Status (95);
         else
            Write_All (1, C.int'Image (Descendant));
         end if;
      end;
   end if;
end Subprocess_Fixture;
