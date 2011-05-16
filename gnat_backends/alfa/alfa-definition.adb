------------------------------------------------------------------------------
--                                                                          --
--                         GNAT BACK-END COMPONENTS                         --
--                                                                          --
--                       A L F A . D E F I N I T I O N                      --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--             Copyright (C) 2011, Free Software Foundation, Inc.           --
--                                                                          --
-- GNAT is free software;  you can  redistribute it  and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  GNAT is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License --
-- for  more details.  You should have  received  a copy of the GNU General --
-- Public License  distributed with GNAT; see file COPYING3.  If not, go to --
-- http://www.gnu.org/licenses for a complete copy of the license.          --
--                                                                          --
-- GNAT was originally developed  by the GNAT team at  New York University. --
-- Extensive contributions were provided by Ada Core Technologies Inc.      --
--                                                                          --
------------------------------------------------------------------------------

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;           use Ada.Text_IO;

with AA_Util;               use AA_Util;
with Alloc;                 use Alloc;
with Atree;                 use Atree;
with Einfo;                 use Einfo;
with Errout;                use Errout;
with Namet;                 use Namet;
with Nlists;                use Nlists;
with Snames;                use Snames;
with Sem_Eval;              use Sem_Eval;
with Sem_Util;              use Sem_Util;
with Sinfo;                 use Sinfo;
with Sinput;                use Sinput;
with Stand;                 use Stand;
with Table;

with ALFA.Common;           use ALFA.Common;
with ALFA.Frame_Conditions; use ALFA.Frame_Conditions;

package body ALFA.Definition is

   Output_File : Ada.Text_IO.File_Type;
   --  <file>.alfa in which this pass generates information about subprograms
   --  in ALFA and subprograms not in ALFA.

   ---------------------
   -- Local Constants --
   ---------------------

   --  Standard types which are in ALFA are associated to True

   Standard_Type_Is_In_ALFA : constant array (S_Types) of Boolean :=
     (S_Boolean             => True,

      S_Short_Short_Integer => True,
      S_Short_Integer       => True,
      S_Integer             => True,
      S_Long_Integer        => True,
      S_Long_Long_Integer   => True,

      S_Natural             => True,
      S_Positive            => True,

      S_Short_Float         => False,
      S_Float               => False,
      S_Long_Float          => False,
      S_Long_Long_Float     => False,

      S_Character           => True,
      S_Wide_Character      => True,
      S_Wide_Wide_Character => True,

      S_String              => True,
      S_Wide_String         => False,
      S_Wide_Wide_String    => False,

      S_Duration            => False);

   Violation_Msg : constant array (V_Extensions) of Unbounded_String :=
     (V_Block_Statement => To_Unbounded_String ("block statement"),
      V_Container       => To_Unbounded_String ("container"),
      V_Discr           => To_Unbounded_String ("discriminant"),
      V_Dispatch        => To_Unbounded_String ("dispatch"),
      V_Generic         => To_Unbounded_String ("generic"),
      V_Impure_Function => To_Unbounded_String ("impure function"),
      V_Slice           => To_Unbounded_String ("slice"),
      V_Tagged          => To_Unbounded_String ("tagged type"));

   ------------------------------------------------
   -- Pragma Annotate (GNATprove, Force/Disable) --
   ------------------------------------------------

   Formal_Proof_On  : Id_Set.Set;
   Formal_Proof_Off : Id_Set.Set;

   function Formal_Proof_Currently_Disabled return Boolean;
   --  Determine the most top-level scope to have formal proof forced or
   --  disabled, and return True if formal proof is disabled. Return False in
   --  all other cases.

   function Formal_Proof_Currently_Forced return Boolean;
   --  Determine the most top-level scope to have formal proof forced or
   --  disabled, and return True if formal proof is forced. Return False in all
   --  other cases. This is useful to notify the user about ALFA violations in
   --  a scope where formal proof is forced.

   ----------------
   -- ALFA Marks --
   ----------------

   Standard_In_ALFA : Id_Set.Set;
   --  Entities from package Standard which are in ALFA

   Specs_In_Alfa    : Id_Set.Set;
   --  Subprogram entities whose spec is in Alfa

   Bodies_In_Alfa   : Id_Set.Set;
   --  Subprogram entities whose body is in Alfa

   type Violations is array (Violation_Kind) of Id_Set.Set;

   Spec_Violations : Violations;
   --  Sets of entities which violate ALFA restrictions, per violation kind

   Body_Violations : Violations;
   --  Sets of subprogram entities whose body violate ALFA restrictions, per
   --  violation kind.

   function Complete_Error_Msg
     (Msg : String;
      V   : Violation_Kind) return String;

   procedure Inherit_Violations (A : in out Violations; To, From : Entity_Id);

   function Body_Is_Computed_In_ALFA (Id : Entity_Id) return Boolean;

   function Spec_Is_Computed_In_ALFA (Id : Entity_Id) return Boolean;

   -----------------
   -- Scope Stack --
   -----------------

   --  A stack of scopes records scopes currently open. The entity referenced
   --  can be:
   --    . a package spec
   --    . a package body
   --    . a subprogram spec (even when treating the subprogram body)
   --    . a variable (when treating initializing expression)
   --    . a type (when treating a type declaration)
   --    . null (for a logical scope)

   type Scope_Record is record
      Entity     : Entity_Id;
      Is_Body    : Boolean;  --  True when treating a package/subprogram body
      Is_Generic : Boolean;  --  True for generic declaration or instantiation
      Is_Logic   : Boolean;  --  True for assertions, pre- and postconditions
   end record;

   First_Scope_Index : constant := 0;

   package Scope_Stack is new Table.Table (
     Table_Component_Type => Scope_Record,
     Table_Index_Type     => Int,
     Table_Low_Bound      => First_Scope_Index,
     Table_Initial        => Alloc.Scope_Stack_Initial,
     Table_Increment      => Alloc.Scope_Stack_Increment,
     Table_Name           => "ALFA.Definition.Scope_Stack");

   function Current_Scope return Scope_Record;
   --  Return the top-most scope that is not null

   function Previous_Scope return Scope_Record;
   --  Return the top-most scope that is not null after skipping the current
   --  scope.

   function In_Generic_Scope return Boolean is
     (for some S in First_Scope_Index .. Scope_Stack.Last =>
        Scope_Stack.Table (S).Is_Generic);
   --  Return True if there is a generic scope in the current scope stack

   function In_Logic_Scope return Boolean is
     (for some S in First_Scope_Index .. Scope_Stack.Last =>
        Scope_Stack.Table (S).Is_Logic);
   --  Return True if there is a logic scope in the current scope stack

   procedure Pop_Scope (E : Entity_Id);
   --  Remove the top scope in the stack, which should match with entity E

   procedure Push_Scope
     (E          : Entity_Id;
      Is_Body    : Boolean := False;
      Is_Generic : Boolean := False);
   --  Set entity S as the top scope in the stack

   procedure Push_Logic_Scope;
   --  Push a logic scope as the top scope in the stack

   procedure Pop_Logic_Scope;
   --  Remove the top scope in the stack, which should be a logic scope

   -----------------------
   -- Local Subprograms --
   -----------------------

   procedure Mark (N : Node_Id);
   --  Generic procedure for marking code as in ALFA / not in ALFA

   procedure Mark_List (L : List_Id);
   --  Call Mark on all nodes in list L

   procedure Mark_Non_ALFA
     (Msg    : String;
      N      : Node_Id;
      V      : Violation_Kind := V_Other;
      Silent : Boolean        := False);
   --  Mark the current subprogram containing node N (if any) as not being in
   --  ALFA. If the corresponding scope is a spec, then mark the subprogram
   --  specification as not in ALFA. Otherwise, mark the subprogram body as not
   --  in ALFA.
   --
   --  Indeed, this procedure may be called during the analysis of a
   --  precondition or postcondition, or during the analysis of a subprogram's
   --  body. In the first case, the specification of the current subprogram
   --  must be marked as not being in ALFA, as the contract is considered to be
   --  part of the specification, so that calls to this subprogram are not in
   --  ALFA. In the second case, mark the body as not being in ALFA, which does
   --  not prevent the subprogram's specification, and calls to the subprogram,
   --  from being in ALFA.
   --
   --  If the subprogram being marked as not in ALFA is annotated with
   --  formal proof forced, then an error is issued with message Msg on node N,
   --  unless Silent is True.

   procedure Mark_Non_ALFA
     (Msg  : String;
      N    : Node_Id;
      From : Entity_Id);
   --  Similar to Mark_Non_ALFA taking a Violation_Kind as parameter, except
   --  here violations are inherited from entity From.

   procedure Mark_Non_ALFA_Declaration
     (Msg    : String;
      N      : Node_Id;
      V      : Violation_Kind := V_Other;
      Silent : Boolean        := False);
   --  Mark the declaration N as not being in ALFA, as well as the enclosing
   --  subprogram if any. If Silent is True, then never issue an error message,
   --  even if formal proof is forced.

   procedure Mark_Non_ALFA_Declaration
     (Msg  : String;
      N    : Node_Id;
      From : Entity_Id);
   --  Similar to Mark_Non_ALFA_Declaration taking a Violation_Kind as
   --  parameter, except here violations are inherited from entity From.

   generic
      with procedure Mark_Body_Violations (E : Entity_Id) is <>;
      with procedure Mark_Spec_Violations (E : Entity_Id) is <>;
   procedure Mark_Violations (Scop : Scope_Record);
   --  Helper procedure called in Mark_Non_ALFA

   --  Special treatment for marking some kinds of nodes

   procedure Mark_Attribute_Reference         (N : Node_Id);
   procedure Mark_Binary_Op                   (N : Node_Id);
   procedure Mark_Call                        (N : Node_Id);
   procedure Mark_Component_Declaration       (N : Node_Id);
   procedure Mark_Conditional_Expression      (N : Node_Id);
   procedure Mark_Full_Type_Declaration       (N : Node_Id);
   procedure Mark_Function_Specification      (N : Node_Id);
   procedure Mark_Handled_Statements          (N : Node_Id);
   procedure Mark_Identifier_Or_Expanded_Name (N : Node_Id);
   procedure Mark_If_Statement                (N : Node_Id);
   procedure Mark_Iteration_Scheme            (N : Node_Id);
   procedure Mark_Object_Declaration          (N : Node_Id);
   procedure Mark_Object_Renaming_Declaration (N : Node_Id);
   procedure Mark_Package_Body                (N : Node_Id);
   procedure Mark_Package_Declaration         (N : Node_Id);
   procedure Mark_Package_Specification       (N : Node_Id);
   procedure Mark_Pragma                      (N : Node_Id);
   procedure Mark_Simple_Return_Statement     (N : Node_Id);
   procedure Mark_Subprogram_Body             (N : Node_Id);
   procedure Mark_Subprogram_Declaration      (N : Node_Id);
   procedure Mark_Subprogram_Specification    (N : Node_Id);
   procedure Mark_Subtype_Declaration         (N : Node_Id);
   procedure Mark_Subtype_Indication          (N : Node_Id);
   procedure Mark_Type_Conversion             (N : Node_Id);
   procedure Mark_Type_Definition             (Id : Entity_Id; N : Node_Id);
   procedure Mark_Unary_Op                    (N : Node_Id);

   ------------------------------
   -- Body_Is_Computed_In_ALFA --
   ------------------------------

   function Body_Is_Computed_In_ALFA (Id : Entity_Id) return Boolean is
     (for all S of Body_Violations => not S.Contains (Id));

   ---------------------
   -- Body_Is_In_ALFA --
   ---------------------

   function Body_Is_In_ALFA (Id : Entity_Id) return Boolean is
     (Id_Set.Contains (Bodies_In_Alfa, Id));

   ----------------------------
   -- Close_ALFA_Output_File --
   ----------------------------

   procedure Close_ALFA_Output_File is
   begin
      Close (Output_File);
   end Close_ALFA_Output_File;

   ------------------------
   -- Complete_Error_Msg --
   ------------------------

   function Complete_Error_Msg
     (Msg : String;
      V   : Violation_Kind) return String is
   begin
      case V is
         when V_Implem =>
            return Msg & " is not yet implemented in Alfa";
         when V_Other =>
            return Msg & " is not in Alfa";
         when V_Extensions =>
            return Msg & " is not yet implemented in Alfa ("
              & To_String (Violation_Msg (V)) & ")";
      end case;
   end Complete_Error_Msg;

   -------------------
   -- Current_Scope --
   -------------------

   function Current_Scope return Scope_Record is
      Idx : Int := Scope_Stack.Last;

   begin
      while Idx /= First_Scope_Index - 1
        and then No (Scope_Stack.Table (Idx).Entity)
      loop
         Idx := Idx - 1;
      end loop;

      pragma Assert (Idx /= First_Scope_Index - 1);

      return Scope_Stack.Table (Idx);
   end Current_Scope;

   -------------------------------------
   -- Formal_Proof_Currently_Disabled --
   -------------------------------------

   function Formal_Proof_Currently_Disabled return Boolean is
   begin
      for Idx in reverse Scope_Stack.First .. Scope_Stack.Last loop
         declare
            E : constant Entity_Id := Scope_Stack.Table (Idx).Entity;
         begin
            if Formal_Proof_Off.Contains (E) then
               return True;
            elsif Formal_Proof_On.Contains (E) then
               return False;
            end if;
         end;
      end loop;
      return False;
   end Formal_Proof_Currently_Disabled;

   -----------------------------------
   -- Formal_Proof_Currently_Forced --
   -----------------------------------

   function Formal_Proof_Currently_Forced return Boolean is
   begin
      for Idx in reverse Scope_Stack.First .. Scope_Stack.Last loop
         declare
            E : constant Entity_Id := Scope_Stack.Table (Idx).Entity;
         begin
            if Formal_Proof_On.Contains (E) then
               return True;
            elsif Formal_Proof_Off.Contains (E) then
               return False;
            end if;
         end;
      end loop;
      return False;
   end Formal_Proof_Currently_Forced;

   ------------------------
   -- Inherit_Violations --
   ------------------------

   procedure Inherit_Violations (A : in out Violations; To, From : Entity_Id)
   is
   begin
      if Scope (From) = Standard_Standard then
         A (V_Other).Include (To);
      else
         pragma Assert (for some S of Spec_Violations => S.Contains (From));

         for V in Violation_Kind loop
            if Spec_Violations (V).Contains (From) then
               A (V).Include (To);
            end if;
         end loop;
      end if;
   end Inherit_Violations;

   ----------------
   -- Is_In_ALFA --
   ----------------

   function Is_In_ALFA (Id : Entity_Id) return Boolean is
   begin
      if Scope (Id) = Standard_Standard
        and then not (Is_Subprogram (Id)
                       or else Ekind (Id) = E_Package
                       or else Ekind (Id) = E_Package_Body)
      then
         return Standard_In_ALFA.Contains (Id);
      else
         return (for all S of Spec_Violations => not S.Contains (Id));
      end if;
   end Is_In_ALFA;

   ----------
   -- Mark --
   ----------

   procedure Mark (N : Node_Id) is
   begin
      --  Mark all declarations inside generics as not in ALFA

      if (Nkind (N) in N_Declaration
           or else Nkind (N) in N_Later_Decl_Item)
        and then In_Generic_Scope
      then
         Mark_Non_ALFA_Declaration ("generic", N, V_Generic);
      end if;

      --  Dispatch on node kind

      case Nkind (N) is
         when N_Abstract_Subprogram_Declaration =>
            Mark_Non_ALFA ("abstract subprogram", N, V_Tagged);

         when N_Aggregate =>
            Mark_Non_ALFA ("aggregate", N, V_Implem);

         when N_Allocator =>
            Mark_Non_ALFA ("allocator", N);

         when N_Assignment_Statement =>
            Mark (Name (N));
            Mark (Expression (N));

         when N_At_Clause =>
            Mark_Non_ALFA ("at clause", N);

         when N_Attribute_Reference =>
            Mark_Attribute_Reference (N);

         when N_Attribute_Definition_Clause   =>
            Mark_Non_ALFA ("attribute definition clause", N);

         when N_Binary_Op =>
            Mark_Binary_Op (N);

         when N_Block_Statement =>
            Mark_Non_ALFA ("block statement", N, V_Block_Statement);
            Mark_List (Declarations (N));
            Mark (Handled_Statement_Sequence (N));

         when N_Case_Expression | N_Case_Statement =>
            Mark (Expression (N));
            Mark_List (Alternatives (N));

         when N_Case_Expression_Alternative =>
            pragma Assert (No (Actions (N)));
            Mark (Expression (N));

         when N_Case_Statement_Alternative =>
            Mark_List (Statements (N));

         when N_Code_Statement =>
            Mark_Non_ALFA ("code statement", N);

         when N_Component_Declaration =>
            Mark_Component_Declaration (N);

         when N_Conditional_Expression =>
            Mark_Conditional_Expression (N);

         when N_Enumeration_Representation_Clause =>
            Mark_Non_ALFA ("enumeration representation clause", N);

         when N_Exception_Declaration          |
              N_Exception_Renaming_Declaration =>
            Mark_Non_ALFA_Declaration ("exception", N);

         when N_Exit_Statement =>
            if Present (Condition (N)) then
               Mark (Condition (N));
            end if;

         when N_Expanded_Name =>
            Mark_Identifier_Or_Expanded_Name (N);

         when N_Explicit_Dereference =>
            Mark_Non_ALFA ("explicit dereference", N);

         when N_Expression_With_Actions =>
            Mark_List (Actions (N));
            Mark (Expression (N));

         when N_Extended_Return_Statement =>
            Mark_Non_ALFA ("extended RETURN", N, V_Implem);

         when N_Extension_Aggregate =>
            Mark_Non_ALFA ("extension aggregate", N, V_Implem);

         when N_Formal_Object_Declaration |
              N_Formal_Package_Declaration |
              N_Formal_Subprogram_Declaration |
              N_Formal_Type_Declaration =>
            Mark_Non_ALFA_Declaration
              ("formal generic parameter", N, V_Generic);

         when N_Free_Statement =>
            Mark_Non_ALFA ("free statement", N);

         when N_Freeze_Entity =>
            if Present (Actions (N)) then
               Mark_List (Actions (N));
            end if;

         when N_Full_Type_Declaration =>
            Mark_Full_Type_Declaration (N);

         when N_Function_Call =>
            Mark_Call (N);

         when N_Function_Instantiation =>
            Mark_Non_ALFA ("function instantiation", N, V_Generic);

         when N_Generic_Function_Renaming_Declaration |
              N_Generic_Package_Declaration |
              N_Generic_Package_Renaming_Declaration |
              N_Generic_Procedure_Renaming_Declaration |
              N_Generic_Subprogram_Declaration =>
            Mark_Non_ALFA ("generic declaration", N, V_Generic);

         when N_Goto_Statement =>
            Mark_Non_ALFA ("goto statement", N);

         when N_Handled_Sequence_Of_Statements =>
            Mark_Handled_Statements (N);

         when N_Identifier =>
            Mark_Identifier_Or_Expanded_Name (N);

         when N_If_Statement =>
            Mark_If_Statement (N);

         --  Expansion rewrites complex membership tests into simpler ones

         when N_Membership_Test =>
            pragma Assert (No (Alternatives (N)));
            Mark (Left_Opnd (N));
            Mark (Right_Opnd (N));

         when N_Indexed_Component =>
            Mark (Prefix (N));
            Mark_List (Expressions (N));

         when N_Iterator_Specification =>
            Mark_Non_ALFA ("iterator specification", N, V_Container);

         when N_Loop_Statement =>
            if Present (Iteration_Scheme (N)) then
               Mark_Iteration_Scheme (Iteration_Scheme (N));
            end if;
            Mark_List (Statements (N));

         when N_Null =>
            Mark_Non_ALFA ("null", N);

         when N_Object_Declaration =>
            Mark_Object_Declaration (N);

         when N_Object_Renaming_Declaration =>
            Mark_Object_Renaming_Declaration (N);

         when N_Unary_Op =>
            Mark_Unary_Op (N);

         when N_Package_Body =>
            Mark_Package_Body (N);

         when N_Package_Body_Stub =>
            Mark_Package_Body (Get_Body_From_Stub (N));

         when N_Package_Declaration =>
            Mark_Package_Declaration (N);

         when N_Package_Instantiation =>
            Mark_Non_ALFA ("package instantiation", N, V_Generic);

         when N_Package_Specification =>
            Mark_Package_Specification (N);

         when N_Parameter_Association =>
            Mark (Explicit_Actual_Parameter (N));

         when N_Pragma =>
            Mark_Pragma (N);

         when N_Procedure_Call_Statement =>
            Mark_Call (N);

         when N_Procedure_Instantiation =>
            Mark_Non_ALFA ("procedure instantiation", N, V_Generic);

         when N_Qualified_Expression =>
            Mark_Non_ALFA ("qualified expression", N, V_Implem);

         when N_Quantified_Expression =>
            Mark (Condition (N));

         when N_Raise_Statement |
              N_Raise_xxx_Error =>
            Mark_Non_ALFA ("raise statement", N);

         when N_Range =>
            Mark (Low_Bound (N));
            Mark (High_Bound (N));

         when N_Record_Representation_Clause =>
            Mark_Non_ALFA ("record representation clause", N);

         when N_Reference =>
            Mark_Non_ALFA ("reference", N);

         when N_Short_Circuit =>
            pragma Assert (No (Actions (N)));
            Mark (Left_Opnd (N));
            Mark (Right_Opnd (N));

         when N_Simple_Return_Statement =>
            Mark_Simple_Return_Statement (N);

         when N_Selected_Component =>
            --  ??? Check that selector and prefix are really in ALFA
            Mark (Prefix (N));
            Mark (Selector_Name (N));

         when N_Slice =>
            Mark_Non_ALFA ("slice", N, V_Slice);

         when N_Subprogram_Body =>
            if Acts_As_Spec (N) then
               Mark_Subprogram_Declaration (N);
            end if;
            Mark_Subprogram_Body (N);

         when N_Subprogram_Body_Stub =>
            if Is_Subprogram_Stub_Without_Prior_Declaration (N) then
               Mark_Subprogram_Declaration (Get_Body_From_Stub (N));
            end if;
            Mark_Subprogram_Body (Get_Body_From_Stub (N));

         when N_Subprogram_Declaration =>
            Mark_Subprogram_Declaration (N);

         when N_Subtype_Declaration =>
            Mark_Subtype_Declaration (N);

         when N_Subtype_Indication =>
            Mark_Subtype_Indication (N);

         when N_Task_Type_Declaration =>
            Mark_Non_ALFA ("task type", N);

         when N_Type_Conversion =>
            Mark_Type_Conversion (N);

         when N_Unchecked_Expression =>
            Mark_Non_ALFA ("unchecked expression", N);

         when N_Unchecked_Type_Conversion =>
            if Comes_From_Source (N) then
               Mark_Non_ALFA ("unchecked type conversion", N);
            else
               Mark (Expression (N));
            end if;

         when N_Validate_Unchecked_Conversion =>
            Mark_Non_ALFA ("unchecked conversion", N);

         when N_Variant_Part =>
            Mark_Non_ALFA ("variant part", N, V_Discr);

         --  The following kinds can be safely ignored by marking

         when N_Character_Literal               |
              N_Implicit_Label_Declaration      |
              N_Incomplete_Type_Declaration     |
              N_Integer_Literal                 |
              N_Itype_Reference                 |
              N_Label                           |
              N_Null_Statement                  |
              N_Number_Declaration              |
              N_Operator_Symbol                 |
              N_Others_Choice                   |
              N_Package_Renaming_Declaration    |
              N_Private_Extension_Declaration   |
              N_Private_Type_Declaration        |
              N_Real_Literal                    |
              N_String_Literal                  |
              N_Subprogram_Info                 |
              N_Subprogram_Renaming_Declaration |
              N_Use_Package_Clause              |
              N_Use_Type_Clause                 |
              N_With_Clause                     =>
            null;

         --  The following kinds are rewritten by expansion

         when N_Expression_Function |
              N_Subunit             =>
            raise Program_Error;

         --  Mark should not be called on other kinds

         when others =>
            raise Program_Error;
      end case;
   end Mark;

   ------------------------------
   -- Mark_Attribute_Reference --
   ------------------------------

   procedure Mark_Attribute_Reference (N : Node_Id) is
      Aname   : constant Name_Id      := Attribute_Name (N);
      P       : constant Node_Id      := Prefix (N);
      Exprs   : constant List_Id      := Expressions (N);
      Attr_Id : constant Attribute_Id := Get_Attribute_Id (Aname);

   begin
      case Attr_Id is
         when Attribute_Result | Attribute_Old =>
            null;
         when Attribute_First | Attribute_Last | Attribute_Length =>
            Mark (Prefix (N));
         when others =>
            Mark_Non_ALFA ("attribute", N, V_Implem);
      end case;

      Mark (P);
      if Present (Exprs) then
         Mark_List (Exprs);
      end if;
   end Mark_Attribute_Reference;

   --------------------
   -- Mark_Binary_Op --
   --------------------

   procedure Mark_Binary_Op (N : Node_Id) is
      Left_T : constant Entity_Id := Etype (Left_Opnd (N));

   begin
      case N_Binary_Op'(Nkind (N)) is
         when N_Op_Concat =>
            Mark_Non_ALFA ("concatenation", N, V_Implem);

         when N_Op_Lt | N_Op_Le | N_Op_Gt | N_Op_Ge =>
            if Is_Boolean_Type (Left_T) then
               Mark_Non_ALFA
                 ("ordering operator on boolean type", N);

            elsif Is_Array_Type (Left_T) then
               Mark_Non_ALFA
                 ("ordering operator on array type", N);
            end if;

         when N_Op_Eq | N_Op_Ne =>
            if Is_Array_Type (Left_T) then
               Mark_Non_ALFA
                 ("equality operator on array type", N);
            end if;

         when N_Op_And | N_Op_Or =>
            if Is_Array_Type (Left_T)
              and then Nkind (N) in N_Binary_Op
            then
               Mark_Non_ALFA
                 ("binary operator on array type", N);
            end if;

         --  Do not allow arithmetic operations which could be reordered by the
         --  compiler, like "A + B - C", as a given ordering may overflow and
         --  another may not.

         when N_Op_Add | N_Op_Subtract =>
            if Nkind_In (Left_Opnd (N), N_Op_Add, N_Op_Subtract)
              and then Paren_Count (Left_Opnd (N)) = 0
            then
               Mark_Non_ALFA
                 ("possible re-ordering due to missing parentheses",
                  Left_Opnd (N));
            end if;

            if Nkind_In (Right_Opnd (N), N_Op_Add, N_Op_Subtract)
              and then Paren_Count (Right_Opnd (N)) = 0
            then
               Mark_Non_ALFA
                 ("possible re-ordering due to missing parentheses",
                  Right_Opnd (N));
            end if;

         when N_Op_Multiply | N_Op_Divide | N_Op_Rem | N_Op_Mod =>
            if Nkind (Left_Opnd (N)) in N_Multiplying_Operator
              and then Paren_Count (Left_Opnd (N)) = 0
            then
               Mark_Non_ALFA
                 ("possible re-ordering due to missing parentheses",
                  Left_Opnd (N));
            end if;

            if Nkind (Right_Opnd (N)) in N_Multiplying_Operator
              and then Paren_Count (Right_Opnd (N)) = 0
            then
               Mark_Non_ALFA
                 ("possible re-ordering due to missing parentheses",
                  Right_Opnd (N));
            end if;

         when N_Op_Expon |
              N_Op_Xor   |
              N_Op_Shift =>
            Mark_Non_ALFA ("operator", N, V_Implem);
      end case;

      Mark (Left_Opnd (N));
      Mark (Right_Opnd (N));
   end Mark_Binary_Op;

   ---------------
   -- Mark_Call --
   ---------------

   procedure Mark_Call (N : Node_Id) is
      Nam     : constant Node_Id := Name (N);
      Actuals : constant List_Id := Parameter_Associations (N);

   begin
      if Present (Actuals) then
         Mark_List (Actuals);
      end if;

      --  If this is an indirect call, an entry call, a call to a protected
      --  operation or the subprogram called is not in ALFA, then the call is
      --  not in ALFA.

      if not Is_Entity_Name (Nam) then
         Mark_Non_ALFA ("call", N);

      elsif not Spec_Is_In_ALFA (Entity (Nam)) then
         Mark_Non_ALFA ("subprogram called", N, From => Entity (Nam));

      elsif In_Logic_Scope then

         if Has_Global_Reads (Entity (Nam)) then
            Mark_Non_ALFA ("global read in subprogram called in logic",
                           N, V_Implem);

         elsif Nkind (Original_Node (Parent (Parent (Entity (Nam)))))
           /= N_Expression_Function
         then
            Mark_Non_ALFA ("regular function called in logic", N, V_Implem);
         end if;

      end if;
   end Mark_Call;

   ---------------------------
   -- Mark_Compilation_Unit --
   ---------------------------

   procedure Mark_Compilation_Unit (N : Node_Id) is
   begin
      --  Separately mark declarations from Standard as in ALFA or not

      if Defining_Entity (N) /= Standard_Standard then
         Push_Scope (Standard_Standard);
         Mark (N);
         Pop_Scope (Standard_Standard);
      end if;
   end Mark_Compilation_Unit;

   --------------------------------
   -- Mark_Component_Declaration --
   --------------------------------

   procedure Mark_Component_Declaration (N : Node_Id) is
      Def : constant Node_Id   := Component_Definition (N);

   begin
      if Aliased_Present (Def) then
         Mark_Non_ALFA_Declaration ("ALIASED", N);
      end if;

      if Present (Access_Definition (Def)) then
         Mark_Non_ALFA ("access type", Def);
      else
         Mark_Subtype_Indication (Subtype_Indication (Def));
      end if;
   end Mark_Component_Declaration;

   ---------------------------------
   -- Mark_Conditional_Expression --
   ---------------------------------

   procedure Mark_Conditional_Expression (N : Node_Id) is
      Condition : constant Node_Id := First (Expressions (N));
      Then_Expr : constant Node_Id := Next (Condition);
      Else_Expr : Node_Id;

   begin
      pragma Assert (No (Then_Actions (N)));
      pragma Assert (No (Else_Actions (N)));

      Else_Expr := Next (Then_Expr);

      Mark (Condition);
      Mark (Then_Expr);

      if Present (Else_Expr) then
         Mark (Else_Expr);
      end if;
   end Mark_Conditional_Expression;

   --------------------------------
   -- Mark_Full_Type_Declaration --
   --------------------------------

   procedure Mark_Full_Type_Declaration (N : Node_Id) is
      Id  : constant Entity_Id := Defining_Identifier (N);
      Def : constant Node_Id   := Type_Definition (N);
   begin
      Push_Scope (Id);
      Mark_Type_Definition (Id, Def);
      Pop_Scope (Id);
   end Mark_Full_Type_Declaration;

   ---------------------------------
   -- Mark_Function_Specification --
   ---------------------------------

   procedure Mark_Function_Specification (N : Node_Id) is
      Id       : constant Entity_Id := Unique_Defining_Entity (N);
      Params   : constant List_Id   := Parameter_Specifications (N);
      Param    : Node_Id;
      Param_Id : Entity_Id;

   begin
      if Has_Global_Writes (Id) then
         Mark_Non_ALFA ("function with side-effect", Id, V_Impure_Function);
         return;
      end if;

      if Is_Non_Empty_List (Params) then
         Param := First (Params);
         while Present (Param) loop
            Param_Id := Defining_Identifier (Param);

            case Ekind (Param_Id) is
               when E_Out_Parameter =>
                  Mark_Non_ALFA ("function with OUT parameter", Id,
                                 V_Impure_Function);
                  return;
               when E_In_Out_Parameter =>
                  Mark_Non_ALFA ("function with IN OUT parameter", Id,
                                 V_Impure_Function);
                  return;
               when others =>
                  null;
            end case;

            Next (Param);
         end loop;
      end if;
   end Mark_Function_Specification;

   -----------------------------
   -- Mark_Handled_Statements --
   -----------------------------

   procedure Mark_Handled_Statements (N : Node_Id) is
      Handlers : constant List_Id := Exception_Handlers (N);

   begin
      if Present (Handlers) then
         Mark_Non_ALFA ("handler", First (Handlers));
      end if;

      Mark_List (Statements (N));
   end Mark_Handled_Statements;

   ---------------------
   -- Mark_Identifier --
   ---------------------

   procedure Mark_Identifier_Or_Expanded_Name (N : Node_Id) is
   begin
      if Is_Entity_Name (N)
        and then not Is_In_ALFA (Entity (N))
      then
         Mark_Non_ALFA ("entity", N, From => Entity (N));
      end if;
   end Mark_Identifier_Or_Expanded_Name;

   -----------------------
   -- Mark_If_Statement --
   -----------------------

   procedure Mark_If_Statement (N : Node_Id) is
   begin
      Mark (Condition (N));

      Mark_List (Then_Statements (N));

      if Present (Elsif_Parts (N)) then
         declare
            Part : Node_Id;

         begin
            Part := First (Elsif_Parts (N));
            while Present (Part) loop
               Mark (Condition (Part));
               Mark_List (Then_Statements (Part));
               pragma Assert (No (Condition_Actions (Part)));
               Next (Part);
            end loop;
         end;
      end if;

      if Present (Else_Statements (N)) then
         Mark_List (Else_Statements (N));
      end if;
   end Mark_If_Statement;

   ---------------------------
   -- Mark_Iteration_Scheme --
   ---------------------------

   procedure Mark_Iteration_Scheme (N : Node_Id) is
   begin
      pragma Assert (No (Condition_Actions (N)));

      if Present (Condition (N)) then
         Mark (Condition (N));

      elsif Present (Loop_Parameter_Specification (N)) then
         declare
            LP : constant Node_Id   := Loop_Parameter_Specification (N);
            Id : constant Entity_Id := Defining_Identifier (LP);

         begin
            --  The entity for iterating over a loop is always in ALFA if its
            --  type is in ALFA.

            --  ??? This assumes that the type is previously declared, which
            --  should be inserted automatically by the front-end if not in
            --  user code, see K421-020.

            if not Is_In_ALFA (Etype (Id)) then
               Mark_Non_ALFA_Declaration
                 ("type of loop index", LP, From => Etype (Id));
            end if;
         end;

      else
         pragma Assert (Present (Iterator_Specification (N)));
         Mark_Non_ALFA ("loop with iterator", N, V_Implem);
      end if;
   end Mark_Iteration_Scheme;

   ---------------
   -- Mark_List --
   ---------------

   procedure Mark_List (L : List_Id) is
      N : Node_Id;
   begin
      N := First (L);
      while Present (N) loop
         Mark (N);
         Next (N);
      end loop;
   end Mark_List;

   -------------------
   -- Mark_Non_ALFA --
   -------------------

   procedure Mark_Non_ALFA
     (Msg    : String;
      N      : Node_Id;
      V      : Violation_Kind := V_Other;
      Silent : Boolean        := False)
   is
      procedure Mark_Body_Violations (E : Entity_Id);
      procedure Mark_Spec_Violations (E : Entity_Id);

      procedure Mark_Body_Violations (E : Entity_Id) is
      begin
         Body_Violations (V).Include (E);
      end Mark_Body_Violations;

      procedure Mark_Spec_Violations (E : Entity_Id) is
      begin
         Spec_Violations (V).Include (E);
      end Mark_Spec_Violations;

      procedure Mark_Scope is new Mark_Violations;

   begin
      --  If formal proof is forced and node N is not compiler-generated, then
      --  notify the user about the violation.

      if Formal_Proof_Currently_Forced
        and then not Silent
        and then Comes_From_Source (N)
      then
         Error_Msg_F (Complete_Error_Msg (Msg, V), N);
      end if;

      Mark_Scope (Current_Scope);
      if Ekind (Current_Scope.Entity) in Type_Kind then
         Mark_Scope (Previous_Scope);
      end if;
   end Mark_Non_ALFA;

   procedure Mark_Non_ALFA
     (Msg  : String;
      N    : Node_Id;
      From : Entity_Id)
   is
      procedure Mark_Body_Violations (E : Entity_Id);
      procedure Mark_Spec_Violations (E : Entity_Id);

      procedure Mark_Body_Violations (E : Entity_Id) is
      begin
         Inherit_Violations (Body_Violations, From => From, To => E);
      end Mark_Body_Violations;

      procedure Mark_Spec_Violations (E : Entity_Id) is
      begin
         Inherit_Violations (Spec_Violations, From => From, To => E);
      end Mark_Spec_Violations;

      procedure Mark_Scope is new Mark_Violations;

   begin
      --  If formal proof is forced and node N is not compiler-generated, then
      --  notify the user about the violation.

      if Formal_Proof_Currently_Forced
        and then Comes_From_Source (N)
      then
         if Scope (From) = Standard_Standard
           or else Spec_Violations (V_Other).Contains (From)
         then
            Error_Msg_F (Complete_Error_Msg (Msg, V_Other), N);

         elsif (for some V in V_Extensions =>
                  Spec_Violations (V).Contains (From))
         then
            for V in V_Extensions loop
               if Spec_Violations (V).Contains (From) then
                  Error_Msg_F (Complete_Error_Msg (Msg, V), N);
               end if;
            end loop;

         else
            pragma Assert (Spec_Violations (V_Implem).Contains (From));
            Error_Msg_F (Complete_Error_Msg (Msg, V_Implem), N);
         end if;
      end if;

      Mark_Scope (Current_Scope);
      if Ekind (Current_Scope.Entity) in Type_Kind then
         Mark_Scope (Previous_Scope);
      end if;
   end Mark_Non_ALFA;

   -------------------------------
   -- Mark_Non_ALFA_Declaration --
   -------------------------------

   procedure Mark_Non_ALFA_Declaration
     (Msg    : String;
      N      : Node_Id;
      V      : Violation_Kind := V_Other;
      Silent : Boolean        := False) is
   begin
      Spec_Violations (V).Include (Unique_Defining_Entity (N));
      Mark_Non_ALFA (Msg, N, V, Silent);
   end Mark_Non_ALFA_Declaration;

   procedure Mark_Non_ALFA_Declaration
     (Msg  : String;
      N    : Node_Id;
      From : Entity_Id) is
   begin
      Inherit_Violations
        (Spec_Violations, From => From, To => Unique_Defining_Entity (N));
      Mark_Non_ALFA (Msg, N, From);
   end Mark_Non_ALFA_Declaration;

   -----------------------------
   -- Mark_Object_Declaration --
   -----------------------------

   procedure Mark_Object_Declaration (N : Node_Id) is
      Id   : constant Entity_Id := Defining_Entity (N);
      Expr : constant Node_Id   := Expression (N);
      Def  : constant Node_Id   := Object_Definition (N);
   begin
      --  The object is in ALFA if-and-only-if its type is in ALFA and it is
      --  not aliased.

      Push_Scope (Id);

      case Nkind (Def) is
         when N_Array_Type_Definition |
              N_Access_Definition     =>
            Mark_Type_Definition (Etype (Id), Def);

         when N_Identifier         |
              N_Expanded_Name      |
              N_Subtype_Indication =>
            Mark (Def);

         when others =>
            raise Program_Error;
      end case;

      if Aliased_Present (N) then
         Mark_Non_ALFA_Declaration ("ALIASED", N);
      end if;

      if Present (Expr) then
         Mark (Expr);
      end if;

      Pop_Scope (Id);
   end Mark_Object_Declaration;

   --------------------------------------
   -- Mark_Object_Renaming_Declaration --
   --------------------------------------

   procedure Mark_Object_Renaming_Declaration (N : Node_Id) is
      E : constant Entity_Id := Entity (Name (N));
   begin
      if not Is_In_ALFA (E) then
         Mark_Non_ALFA_Declaration ("object being renamed", N, From => E);
      end if;
   end Mark_Object_Renaming_Declaration;

   -----------------------
   -- Mark_Package_Body --
   -----------------------

   procedure Mark_Package_Body (N : Node_Id) is
      HSS : constant Node_Id   := Handled_Statement_Sequence (N);
      Id  : constant Entity_Id := Defining_Entity (N);
      Is_Generic : constant Boolean :=
                     Ekind (Unique_Defining_Entity (N)) = E_Generic_Package;

   begin
      --  The scope entity for a package body is not the same as the scope
      --  entity for a package declaration, which allow separately forcing
      --  formal proof on either the declaration or the body.

      Push_Scope (Id, Is_Generic => Is_Generic);
      Mark_List (Declarations (N));

      if Present (HSS) then
         Mark (HSS);
      end if;

      Pop_Scope (Id);
   end Mark_Package_Body;

   ------------------------------
   -- Mark_Package_Declaration --
   ------------------------------

   procedure Mark_Package_Declaration (N : Node_Id) is
      Id : constant Entity_Id := Unique_Defining_Entity (N);

      --  Rewriting of a package should only occur for a package instantiation,
      --  in which case Is_Rewrite_Insertion return True.

      Is_Generic : constant Boolean := Is_Rewrite_Insertion (N);

   begin
      Push_Scope (Id, Is_Generic => Is_Generic);
      Mark (Specification (N));
      Pop_Scope (Id);
   end Mark_Package_Declaration;

   --------------------------------
   -- Mark_Package_Specification --
   --------------------------------

   procedure Mark_Package_Specification (N : Node_Id) is
      Vis_Decls  : constant List_Id := Visible_Declarations (N);
      Priv_Decls : constant List_Id := Private_Declarations (N);

   begin
      if Present (Vis_Decls) then
         Mark_List (Vis_Decls);
      end if;

      if Present (Priv_Decls) then
         Mark_List (Priv_Decls);
      end if;
   end Mark_Package_Specification;

   -----------------
   -- Mark_Pragma --
   -----------------

   procedure Mark_Pragma (N : Node_Id) is
      Pname   : constant Name_Id   := Pragma_Name (N);
      Prag_Id : constant Pragma_Id := Get_Pragma_Id (Pname);

      Arg  : Node_Id;
      Arg1 : Node_Id;
      Arg2 : Node_Id;
      --  First two pragma arguments (pragma argument association nodes, or
      --  Empty if the corresponding argument does not exist).

   begin
      if Present (Pragma_Argument_Associations (N)) then
         Arg1 := First (Pragma_Argument_Associations (N));

         if Present (Arg1) then
            Arg2 := Next (Arg1);
         end if;
      end if;

      Error_Msg_Name_1 := Pname;

      case Prag_Id is

         --  pragma Annotate (IDENTIFIER [, IDENTIFIER {, ARG}]);
         --  ARG ::= NAME | EXPRESSION

         --  The first two arguments are by convention intended to refer to an
         --  external tool and a tool-specific function. These arguments are
         --  not analyzed.

         --  The following is a special form used in conjunction with the
         --  ALFA subset of Ada:

         --    pragma Annotate (GNATprove, MODE);
         --    MODE ::= Force | Ignore

         --    This pragma either forces (mode Force) or disables (mode Ignore)
         --    formal verification of the subprogram in which it is added. When
         --    formal verification is forced, all violations of the the ALFA
         --    subset of Ada present in the subprogram are reported as errors
         --    to the user.

         when Pragma_Annotate =>

            --  Fill in Name_Buffer with Name_GNATprove so that Name_Find
            --  returns the corresponding name.

            Name_Len := 0;
            Add_Str_To_Name_Buffer (Name_GNATprove);

            if Chars (Get_Pragma_Arg (Arg1)) = Name_Find then
               if List_Length (Pragma_Argument_Associations (N)) /= 2 then
                  Error_Msg_N ("wrong number of arguments for annotation", N);
                  return;
               end if;

               Arg := Get_Pragma_Arg (Arg2);
               if Nkind (Arg) /= N_Identifier then
                  Error_Msg_N
                    ("argument for pragma must be an identifier", Arg2);
                  return;
               end if;

               declare
                  Cur_Ent : constant Entity_Id := Current_Scope.Entity;

               begin
                  pragma Assert (Is_Subprogram (Cur_Ent)
                                  or else Ekind (Cur_Ent) = E_Package
                                  or else Ekind (Cur_Ent) = E_Package_Body);

                  --  Check that this is the first occurrence of this pragma
                  --  on the current entity.

                  if Formal_Proof_On.Contains (Cur_Ent) then
                     Error_Msg_N ("formal proof already forced for entity", N);
                     return;

                  elsif Formal_Proof_Off.Contains (Cur_Ent) then
                     Error_Msg_N
                       ("formal proof already disabled for entity", N);
                     return;
                  end if;

                  if Chars (Arg) = Name_Force then
                     if Formal_Proof_Currently_Forced then
                        Error_Msg_N ("?formal proof already forced", N);
                     end if;
                     Formal_Proof_On.Insert (Cur_Ent);
                  elsif Chars (Arg) = Name_Ignore then
                     if Formal_Proof_Currently_Disabled then
                        Error_Msg_N ("?formal proof already disabled", N);
                     end if;
                     Formal_Proof_Off.Insert (Cur_Ent);
                  else
                     Error_Msg_N ("second argument for annotation must be "
                                  & "Force or Ignore", Arg2);
                        return;
                  end if;

                  --  Notify user if some ALFA violation occurred before this
                  --  point in Cur_Ent. These violations are not precisly
                  --  located, but this is better than ignoring these
                  --  violations.

                  if Chars (Arg) = Name_Force
                    and then (not Spec_Is_Computed_In_ALFA (Cur_Ent)
                               or else not Body_Is_Computed_In_ALFA (Cur_Ent))
                  then
                     Error_Msg_N
                       ("annotation is placed after violation of Alfa", N);
                     return;
                  end if;
               end;
            end if;

         --  Pragma Pre/Postconditions are ignored

         when Pragma_Precondition | Pragma_Postcondition =>
            null;

         --  pragma Check ([Name    =>] Identifier,
         --                [Check   =>] Boolean_Expression
         --              [,[Message =>] String_Expression]);

         when Pragma_Check =>

            --  Pragma Check generated for Pre/Postconditions are ignored

            if Chars (Get_Pragma_Arg (Arg1)) /= Name_Precondition
              and then Chars (Get_Pragma_Arg (Arg1)) /= Name_Postcondition
            then
               Push_Logic_Scope;
               Mark (Get_Pragma_Arg (Arg2));
               Pop_Logic_Scope;
            end if;

         when others =>
            Mark_Non_ALFA ("pragma", N);
      end case;
   end Mark_Pragma;

   ----------------------------------
   -- Mark_Simple_Return_Statement --
   ----------------------------------

   procedure Mark_Simple_Return_Statement (N : Node_Id) is
   begin
      if Present (Expression (N)) then
         Mark (Expression (N));
      end if;
   end Mark_Simple_Return_Statement;

   ---------------------------
   -- Mark_Standard_Package --
   ---------------------------

   procedure Mark_Standard_Package is
   begin
      for S in S_Types loop
         if Standard_Type_Is_In_ALFA (S) then
            Standard_In_ALFA.Insert (Standard_Entity (S));
            Standard_In_ALFA.Include (Etype (Standard_Entity (S)));
         end if;
      end loop;

      Standard_In_ALFA.Insert (Standard_False);
      Standard_In_ALFA.Insert (Standard_True);

      Standard_In_ALFA.Insert (Universal_Integer);

      Standard_In_ALFA.Insert (Standard_Integer_8);
      Standard_In_ALFA.Insert (Standard_Integer_16);
      Standard_In_ALFA.Insert (Standard_Integer_32);
      Standard_In_ALFA.Insert (Standard_Integer_64);
   end Mark_Standard_Package;

   --------------------------
   -- Mark_Subprogram_Body --
   --------------------------

   procedure Mark_Subprogram_Body (N : Node_Id) is
      Id  : constant Entity_Id := Unique_Defining_Entity (N);
      HSS : constant Node_Id   := Handled_Statement_Sequence (N);

   begin
      --  Inherit violations from spec to body

      if not Spec_Is_In_ALFA (Id) then
         Inherit_Violations (Body_Violations, From => Id, To => Id);
      end if;

      --  Detect violations in the body itself

      Push_Scope (Id, Is_Body => True);
      Mark_List (Declarations (N));
      Mark (HSS);
      Pop_Scope (Id);

      --  If body is in Alfa, store this information explicitly

      if Body_Is_Computed_In_ALFA (Id) then
         Id_Set.Include (Bodies_In_Alfa, Id);
      end if;

      --  Postprocessing: indicate in output file if subprogram is in ALFA or
      --  not, for debug and verifications.

      if Comes_From_Source (Id) then
         declare
            function Collect_Extension_Violations
              (E : Entity_Id) return String;

            function Collect_Extension_Violations
              (E : Entity_Id) return String
            is
               Msg : Unbounded_String;
            begin
               for V in V_Extensions loop
                  if Body_Violations (V).Contains (E) then
                     if Msg = "" then
                        Msg := Msg & Violation_Msg (V);
                     else
                        Msg := Msg & ", " & Violation_Msg (V);
                     end if;
                  end if;
               end loop;
               return "(" & To_String (Msg) & ")";
            end Collect_Extension_Violations;

            S : constant String :=
                  Name_String (Chars (Id)) & " "
                    & Build_Location_String (Sloc (Defining_Entity (N)));
            --  Location string points to source location for entity. Use the
            --  location of the body (Defining_Entity) rather than the location
            --  of the spec (Id).

            C : constant Character :=
                  (if Body_Is_In_ALFA (Id) then '+' else '-');
            --  Prefix character indicates whether entity is in ALFA (+) or not
            --  in ALFA (-).

            Suffix : constant String :=
                       (if Body_Is_In_ALFA (Id) then ""
                        elsif Body_Violations (V_Other).Contains (Id) then ""
                        elsif (for some V in V_Extensions =>
                                 Body_Violations (V).Contains (Id))
                        then " " & Collect_Extension_Violations (Id)
                        else " (not implemented)");
            --  Suffix string indicates why entity is not in ALFA
         begin
            Put_Line (Output_File, C & S & Suffix);
         end;
      end if;
   end Mark_Subprogram_Body;

   ---------------------------------
   -- Mark_Subprogram_Declaration --
   ---------------------------------

   --  N is either a subprogram declaration node, or a subprogram body node
   --  for those subprograms which do not have a prior declaration (not
   --  counting a stub as a declaration).

   procedure Mark_Subprogram_Declaration (N : Node_Id) is
      PPC  : Node_Id;
      Expr : Node_Id;
      Id   : constant Entity_Id := Unique_Defining_Entity (N);
      Is_Generic : constant Boolean :=
                     Nkind (Original_Node (N)) in N_Subprogram_Instantiation;

   begin
      Push_Scope (Id, Is_Generic => Is_Generic);
      Mark_Subprogram_Specification (Specification (N));

      Push_Logic_Scope;
      PPC := Spec_PPC_List (Contract (Id));
      while Present (PPC) loop
         Expr := Get_Pragma_Arg (First (Pragma_Argument_Associations (PPC)));
         Mark (Expr);
         PPC := Next_Pragma (PPC);
      end loop;
      Pop_Logic_Scope;

      Pop_Scope (Id);

      --  If spec is in Alfa, store this information explicitly

      if Spec_Is_Computed_In_ALFA (Id) then
         Id_Set.Include (Specs_In_Alfa, Id);
      end if;
   end Mark_Subprogram_Declaration;

   -----------------------------------
   -- Mark_Subprogram_Specification --
   -----------------------------------

   procedure Mark_Subprogram_Specification (N : Node_Id) is
      Id         : constant Entity_Id := Unique_Defining_Entity (N);
      Formals    : constant List_Id   := Parameter_Specifications (N);
      Param_Spec : Node_Id;
      Formal     : Entity_Id;

   begin
      if Is_From_Standard_Library (Sloc (N)) then
         Mark_Non_ALFA_Declaration ("standard library", Parent (N), V_Implem);
         return;
      end if;

      if Ekind (Id) = E_Function then
         Mark_Function_Specification (N);
      end if;

      if Present (Formals) then
         Param_Spec := First (Formals);
         while Present (Param_Spec) loop
            Formal := Defining_Identifier (Param_Spec);

            --  The parameter is in ALFA if-and-only-if its type is in ALFA

            if not Is_In_ALFA (Etype (Formal)) then
               Mark_Non_ALFA_Declaration
                 ("type of formal", Param_Spec, From => Etype (Formal));
            end if;

            Next (Param_Spec);
         end loop;

         --  If the result type of a subprogram is not in ALFA, then the
         --  subprogram is not in ALFA.

         if Nkind (N) = N_Function_Specification
           and then not Is_In_ALFA (Etype (Id))
         then
            Mark_Non_ALFA
              ("return type", Result_Definition (N),
               From => Etype (Id));
         end if;
      end if;
   end Mark_Subprogram_Specification;

   ------------------------------
   -- Mark_Subtype_Declaration --
   ------------------------------

   procedure Mark_Subtype_Declaration (N : Node_Id) is
      Id : constant Entity_Id := Defining_Entity (N);
   begin
      Push_Scope (Id);
      Mark (Subtype_Indication (N));
      Pop_Scope (Id);
   end Mark_Subtype_Declaration;

   -----------------------------
   -- Mark_Subtype_Indication --
   -----------------------------

   procedure Mark_Subtype_Indication (N : Node_Id) is
      T       : Entity_Id;
      Cstr    : Node_Id;

   begin
      if Nkind (N) = N_Subtype_Indication then
         T := Etype (Subtype_Mark (N));
      else
         T := Etype (N);
      end if;

      --  Check that the base type is in ALFA

      if not Is_In_ALFA (T) then
         Mark_Non_ALFA ("base type", N, From => T);
      elsif Is_Array_Type (T) then
         Mark_Non_ALFA ("array subtype", N, V_Implem);
      end if;

      if Nkind (N) = N_Subtype_Indication then

         Cstr := Constraint (N);
         case Nkind (Cstr) is
            when N_Range_Constraint =>
               if not Is_Static_Range (Range_Expression (Cstr)) then
                  Mark_Non_ALFA ("non-static range", N, V_Implem);
               end if;

            when N_Index_Or_Discriminant_Constraint =>

               Cstr := First (Constraints (Cstr));
               while Present (Cstr) loop

                  case Nkind (Cstr) is
                     when N_Identifier | N_Expanded_Name =>
                        if not Is_In_ALFA (Entity (Cstr)) then
                           Mark_Non_ALFA
                             ("index type", N, From => Entity (Cstr));
                        end if;

                     when N_Subtype_Indication =>  --  TO DO
                        Mark_Non_ALFA
                          ("index type", N, V_Implem);

                     when N_Range =>
                        if Comes_From_Source (N) and then
                           not Is_Static_Range (Cstr) then
                           Mark_Non_ALFA ("non-static range", N, V_Implem);
                        end if;

                     when N_Discriminant_Association =>
                        Mark_Non_ALFA ("discriminant", N);

                     when others =>
                        raise Program_Error;
                  end case;
                  Next (Cstr);
               end loop;

            when others =>  --  TO DO ???
               raise Program_Error;
         end case;
      end if;
   end Mark_Subtype_Indication;

   --------------------------
   -- Mark_Type_Conversion --
   --------------------------

   procedure Mark_Type_Conversion (N : Node_Id) is
      Expr : constant Node_Id := Expression (N);

   begin
      --  Type conversion between scalar types are allowed in ALFA. All other
      --  type conversions are not allowed.

      if not (Is_Scalar_Type (Etype (Expr))
               and then Is_Scalar_Type (Etype (N)))
      then
         Mark_Non_ALFA
           ("type conversion not between scalar types", N);
      end if;

      Mark (Expr);
   end Mark_Type_Conversion;

   --------------------------
   -- Mark_Type_Definition --
   --------------------------

   procedure Mark_Type_Definition (Id : Entity_Id; N : Node_Id) is
   begin
      case Nkind (N) is
         when N_Array_Type_Definition =>
            declare
               Component_Def : constant Node_Id := Component_Definition (N);
               Component_Typ : constant Node_Id :=
                                 Subtype_Indication (Component_Def);
               Index         : Node_Id;

            begin
               if Nkind (N) = N_Constrained_Array_Definition then
                  Index := First (Discrete_Subtype_Definitions (N));
               else
                  Index := First (Subtype_Marks (N));
               end if;

               --  Check that all index types are in ALFA

               while Present (Index) loop
                  if not Is_In_ALFA (Etype (Index)) then
                     Mark_Non_ALFA
                       ("index type", N, From => Etype (Index));
                  end if;
                  Next_Index (Index);
               end loop;

               --  Access definition for component type is not in ALFA

               if No (Component_Typ) then
                  Mark_Non_ALFA ("access type", N);
               end if;

               --  Check that component type is in ALFA

               if not Is_In_ALFA (Etype (Component_Typ)) then
                  Mark_Non_ALFA
                    ("component type", N, From => Etype (Component_Typ));
               end if;

               --  Check that array bounds are static

               if Nkind (N) = N_Constrained_Array_Definition
                 and then not Has_Static_Array_Bounds (Id)
               then
                  Mark_Non_ALFA
                    ("array type with non-static bounds", N, V_Implem);
               end if;
            end;

         when N_Enumeration_Type_Definition =>
            --  Enumeration type is in ALFA only if it is not a character type

            if Is_Character_Type (Id) then
               Mark_Non_ALFA ("character enumeration type", N);
            end if;

         when N_Signed_Integer_Type_Definition =>
            null;

         when N_Derived_Type_Definition =>
            if Is_Array_Type (Id) then
               Mark_Non_ALFA ("array derived type", N, V_Implem);
            elsif Present (Interface_List (N)) then
               Mark_Non_ALFA ("interface", N);
            elsif Present (Record_Extension_Part (N)) then
               Mark_Non_ALFA ("record extension", N, V_Implem);
            else
               Mark (Subtype_Indication (N));
            end if;

         when N_Record_Definition =>
            if Present (Interface_List (N)) then
               Mark_Non_ALFA ("interface", N);
            elsif Present (Component_List (N))
              and then not Null_Present (Component_List (N))
            then
               if Present (Variant_Part (Component_List (N))) then
                  Mark_Non_ALFA ("variant", N, V_Implem);
               else
                  Mark_List (Component_Items (Component_List (N)));
               end if;
            end if;

         when N_Modular_Type_Definition |
              N_Floating_Point_Definition |
              N_Decimal_Fixed_Point_Definition |
              N_Ordinary_Fixed_Point_Definition =>
            Mark_Non_ALFA ("type definition", N, V_Implem);

         when N_Access_To_Subprogram_Definition |
              N_Access_To_Object_Definition     |
              N_Access_Definition               =>
            Mark_Non_ALFA ("access type", N);

         when others =>
            raise Program_Error;
      end case;
   end Mark_Type_Definition;

   -------------------
   -- Mark_Unary_Op --
   -------------------

   procedure Mark_Unary_Op (N : Node_Id) is
      T : constant Entity_Id := Etype (Right_Opnd (N));

   begin
      case N_Unary_Op'(Nkind (N)) is
         when N_Op_Not =>
            if Is_Array_Type (T) then
               Mark_Non_ALFA ("not operator on array type", N);
            end if;

         when N_Op_Abs =>
            Mark_Non_ALFA ("abs operator", N, V_Implem);

         when N_Op_Plus | N_Op_Minus =>
            null;
      end case;

      Mark (Right_Opnd (N));
   end Mark_Unary_Op;

   ---------------------
   -- Mark_Violations --
   ---------------------

   procedure Mark_Violations (Scop : Scope_Record) is
      Ent : constant Entity_Id := Scop.Entity;

   begin
      case Ekind (Ent) is

         --  Detect violation in initialization of package-level object

         when Object_Kind =>
            if Scop.Is_Body then
               Mark_Body_Violations (Ent);
            else
               Mark_Spec_Violations (Ent);
            end if;

         when Type_Kind =>
            pragma Assert (not Scop.Is_Body);
            Mark_Spec_Violations (Ent);

         when E_Package | E_Package_Body =>
            null;

         --  Detect violation in subprogram declarations and subprogram bodies

         --  If the non-ALFA construct is in a precondition or postcondition,
         --  then mark the subprogram as not in ALFA, because neither the
         --  subprogram nor its callers can be proved formally.
         --
         --  If the non-ALFA construct is in a regular piece of code inside
         --  the body of the subprogram, then mark the subprogram body as not
         --  in ALFA, because the subprogram cannot be proved formally, but its
         --  callers could.

         when Subprogram_Kind =>
            if Scop.Is_Body then
               Mark_Body_Violations (Ent);
            else
               Mark_Spec_Violations (Ent);
            end if;

         when others =>
            raise Program_Error;
      end case;
   end Mark_Violations;

   ---------------------
   -- Pop_Logic_Scope --
   ---------------------

   procedure Pop_Logic_Scope is
      Cur_Scop : Scope_Record renames Scope_Stack.Table (Scope_Stack.Last);
   begin
      pragma Assert (Cur_Scop.Is_Logic);
      Scope_Stack.Decrement_Last;
   end Pop_Logic_Scope;

   ---------------
   -- Pop_Scope --
   ---------------

   procedure Pop_Scope (E : Entity_Id) is
      Cur_Scop : Scope_Record renames Scope_Stack.Table (Scope_Stack.Last);
   begin
      pragma Assert (Cur_Scop.Entity = E);
      Scope_Stack.Decrement_Last;
   end Pop_Scope;

   --------------------
   -- Previous_Scope --
   --------------------

   function Previous_Scope return Scope_Record is
      Idx : Int := Scope_Stack.Last;

   begin
      while Idx /= -1
        and then No (Scope_Stack.Table (Idx).Entity)
      loop
         Idx := Idx - 1;
      end loop;

      Idx := Idx - 1;

      while Idx /= -1
        and then No (Scope_Stack.Table (Idx).Entity)
      loop
         Idx := Idx - 1;
      end loop;

      pragma Assert (Idx /= -1);

      return Scope_Stack.Table (Idx);
   end Previous_Scope;

   ----------------------
   -- Push_Logic_Scope --
   ----------------------

   procedure Push_Logic_Scope is
   begin
      Scope_Stack.Increment_Last;
      Scope_Stack.Table (Scope_Stack.Last) :=
        Scope_Record'(Entity     => Empty,
                      Is_Body    => False,
                      Is_Generic => False,
                      Is_Logic   => True);
   end Push_Logic_Scope;

   ----------------
   -- Push_Scope --
   ----------------

   procedure Push_Scope
     (E          : Entity_Id;
      Is_Body    : Boolean := False;
      Is_Generic : Boolean := False) is
   begin
      Scope_Stack.Increment_Last;
      Scope_Stack.Table (Scope_Stack.Last) :=
        Scope_Record'(Entity     => E,
                      Is_Body    => Is_Body,
                      Is_Generic => Is_Generic,
                      Is_Logic   => False);
   end Push_Scope;

   ------------------------------
   -- Spec_Is_Computed_In_ALFA --
   ------------------------------

   function Spec_Is_Computed_In_ALFA (Id : Entity_Id) return Boolean is
     (for all S of Spec_Violations => not S.Contains (Id));

   ---------------------
   -- Spec_Is_In_ALFA --
   ---------------------

   function Spec_Is_In_ALFA (Id : Entity_Id) return Boolean is
     (Id_Set.Contains (Specs_In_Alfa, Id));

   -----------------------------
   -- Create_ALFA_Output_File --
   -----------------------------

   procedure Create_ALFA_Output_File (Filename : String) is
   begin
      Create (Output_File, Out_File, Filename);
   end Create_ALFA_Output_File;

end ALFA.Definition;
