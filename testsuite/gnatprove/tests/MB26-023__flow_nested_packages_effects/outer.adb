package body Outer
  with SPARK_Mode,
       Refined_State => (State => (Inner.Inner_State,
                                   Inner.Inner_State_2,
                                   Inner.X,
                                   Inner_2.Y,
                                   Inner_2.Z,
                                   Inner_3.W,
                                   Foo))
is
   Foo : Boolean := False;

   package Inner
     with Abstract_State => (Inner_State,
                             Inner_State_2),
          Initializes    => (Inner_State => Init.Var,
                             X           => Init.Var)
   is
      X : Integer := 0;

      function Get_Inner_State return Integer
        with Global => Inner_State;
   end Inner;

   package body Inner
     with Refined_State => (Inner_State   => Y,
                            Inner_State_2 => Z)
   is
      Y : Integer := Init.Var;
      Z : Integer;

      function Get_Inner_State return Integer is (Y)
        with Refined_Global => Y;
   begin
      X := X + Init.Var;
   end Inner;

   package Inner_2
     with Initializes => (Y, Z)
   is
      Y, Z : Integer := 0;
   end Inner_2;

   package Inner_3
     with Initializes => W
   is
      W : Integer := 0;
   end Inner_3;

   package Inner_4
     with Initializes => null
   is
      function Add (X, Y : Integer) return Integer is (X + Y);
   end Inner_4;
end Outer;
