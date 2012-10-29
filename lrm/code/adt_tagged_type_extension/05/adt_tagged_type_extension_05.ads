--# inherit adt_tagged_type_05;
package adt_tagged_type_05.adt_tagged_type_extension_05 is

   type Monitored_Stack is new adt_tagged_type_05.Stack with private;

   overriding
   procedure Clear(S : out Monitored_Stack);
   --# derives S from ;

   overriding
   procedure Push(S : in out Monitored_Stack; X : in Integer);
   --# derives S from S, X;

   function Top_Identity(S : Monitored_Stack) return Integer;
   function Next_Identity(S : Monitored_Stack) return Integer;

private

   type Monitored_Stack is new adt_tagged_type_05.Stack with
      record
         Monitor_Vector : adt_tagged_type_05.Vector;
         Next_Identity_Value : Integer;
      end record;

end adt_tagged_type_05.adt_tagged_type_extension_05;
