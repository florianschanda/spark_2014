package body Initial_Condition_Legal
  with Refined_State => (State => Flag)
is
   Flag : Boolean := True;

   function F1 return Boolean is (Flag)
     with Refined_Global => Flag;
end Initial_Condition_Legal;
