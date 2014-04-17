------------------------------------------------------------------------------
--                                                                          --
--                            GNAT2WHY COMPONENTS                           --
--                                                                          --
--                  F L O W _ E R R O R _ M E S S A G E S                   --
--                                                                          --
--                                 S p e c                                  --
--                                                                          --
--                  Copyright (C) 2013-2014, Altran UK Limited              --
--                                                                          --
-- gnat2why is  free  software;  you can redistribute  it and/or  modify it --
-- under terms of the  GNU General Public License as published  by the Free --
-- Software  Foundation;  either version 3,  or (at your option)  any later --
-- version.  gnat2why is distributed  in the hope that  it will be  useful, --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of  MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public License  distributed with  gnat2why;  see file COPYING3. --
-- If not,  go to  http://www.gnu.org/licenses  for a complete  copy of the --
-- license.                                                                 --
--                                                                          --
------------------------------------------------------------------------------

--  This package provides mechanisms for emitting errors and warnings.

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Types;                 use Types;

with Flow;                  use Flow;
with Flow_Types;            use Flow_Types;

package Flow_Error_Messages is

   Found_Flow_Error : Boolean := False;
   --  This boolean becomes True if we find a flow error or if we find a
   --  flow warning while Warning_Mode = Treat_As_Error.

   procedure Create_Flow_Msgs_File (GNAT_Root : Node_Id);
   --  Writes out the flow messages to the file "unit.flow", in JSON format

   procedure Create_Proof_Msgs_File (GNAT_Root : Node_Id);
   --  Writes out the proof messages to the file "unit.proof", in JSON format

   function Fresh_Trace_File return String;
   --  Returns a name for a trace file. This name should be unique for the
   --  project.

   procedure Error_Msg_Flow
     (FA        : Flow_Analysis_Graphs;
      Msg       : String;
      N         : Node_Id;
      F1        : Flow_Id               := Null_Flow_Id;
      F2        : Flow_Id               := Null_Flow_Id;
      Tag       : String                := "";
      SRM_Ref   : String                := "";
      Tracefile : String                := "";
      Warning   : Boolean               := False;
      Vertex    : Flow_Graphs.Vertex_Id := Flow_Graphs.Null_Vertex)
   with Pre => (if Present (F2) then Present (F1));
   --  Output a message attached to the given node with a substitution using F1
   --  and F2. Use & or # as the substitution characters, which quote the flow
   --  id with or without double quotes respectively. It also adds a JSON entry
   --  in the "unit.flow" file.
   --
   --  SRM_Ref should be a pointer into the SPARK RM. For example:
   --     "1.2.3(4)"
   --
   --  Finally, for debug purposes, Vertex should be set to the vertex
   --  where the error was detected. This is printed in debug mode.

   procedure Error_Msg_Proof
     (N           : Node_Id;
      Msg         : String;
      Is_Proved   : Boolean;
      Tag         : String;
      Tracefile   : String;
      E           : Entity_Id;
      Place_First : Boolean);

end Flow_Error_Messages;
