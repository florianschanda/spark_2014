with System.Storage_Elements;

package body Display with
  SPARK_Mode,
  Refined_State => (State => Internal_State)
is
   protected Internal_State with
     Interrupt_Priority => TuningData.DisplayPriority
   is

      -- add 1 second to stored time and send it to port
      procedure Increment with
        Global  => null,
        Depends => (Internal_State => Internal_State);

      -- clear time to 0 and send it to port;
      procedure Reset with
        Global  => null,
        Depends => (Internal_State => Internal_State);

   private
      Counter : Natural := 0;
   end Internal_State;

   --  External variable Port is a virtual protected object. All accesses to
   --  Port are mediated by protected object Internal_State, which is
   --  specified with the Part_Of aspect on Port.
   Port : Integer := 0 with
     Volatile,
     Async_Readers,
     Address => System.Storage_Elements.To_Address (16#FFFF_FFFF#),
     Part_Of => Internal_State;

   protected body Internal_State is
      procedure Increment is
      begin
         Counter := Counter + 1;
         Port := Counter;
      end Increment;

      procedure Reset is
      begin
         Counter := 0;
         Port := Counter;
      end Reset;
   end Internal_State;

   procedure Initialize with
     Refined_Global  => (In_Out => Internal_State),
     Refined_Depends => (Internal_State => Internal_State)
   is
   begin
      Internal_State.Reset;
   end Initialize;

   procedure AddSecond with
     Refined_Global  => (In_Out => Internal_State),
     Refined_Depends => (Internal_State => Internal_State)
   is
   begin
      Internal_State.Increment;
   end AddSecond;

end Display;
