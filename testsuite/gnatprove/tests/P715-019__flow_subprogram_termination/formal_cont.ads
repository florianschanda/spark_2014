with Ada.Containers.Formal_Doubly_Linked_Lists; use Ada.Containers;

package Formal_Cont with
  SPARK_Mode
is
   -- NONRETURNING CASE

   -- Nonreturning instantiation of "="
   function My_Equal_01 (A, B : Integer) return Boolean;

   -- Package instantiation with nonreturning subprogram
   package New_List_01 is new Ada.Containers.Formal_Doubly_Linked_Lists
     (Element_Type => Integer,
      "="          => My_Equal_01);
   use New_List_01;

   -- Test procedure for nonreturning instantiation
   procedure Test_01;

   -- RETURNING CASE

   -- Returning instantiation of "="
   function My_Equal_02 (A, B : Integer) return Boolean;

   -- Package instantiation with returning subprogram
   package New_List_02 is new Ada.Containers.Formal_Doubly_Linked_Lists
     (Element_Type => Integer,
      "="          => My_Equal_02);
   use New_List_02;

   -- Test procedure for returning instantiation
   procedure Test_02;

end Formal_Cont;