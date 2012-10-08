with Ada.Text_IO; use Ada.Text_IO;
package body PrefixSum is

   procedure Upsweep (A : in out Input; Output_Space : out Positive) is
      Space : Positive := 1;
      Left  : Natural;
      Right : Natural;
      Copy1 : Input;
      Copy2 : Input;
   begin
      Copy1 := A;
      while Space < A'Length loop
         pragma Assert
           (All_Elements_In (A, Space * Maximum)
             and then
           (for all K in A'Range =>
              (if (K + 1) mod 8 = 0
                 and then Space = 8
               then
                  A (K) = Copy1 (0) + Copy1 (1) + Copy1 (2) + Copy1 (3) +
                          Copy1 (4) + Copy1 (5) + Copy1 (6) + Copy1 (7)
               elsif (K + 1) mod 4 = 0
                 and then Space >= 4
               then
                  A (K) = Copy1 (K) + Copy1 (K-1) + Copy1 (K-2) + Copy1 (K-3)
               elsif (K + 1) mod 2 = 0
                 and then Space >= 2
               then
                  A (K) = Copy1 (K) + Copy1 (K-1)
               else
                  A (K) = Copy1 (K))));

         Left := Space - 1;

         Copy2 := A;
         while Left < A'Length loop
            pragma Assert
              (
              (Left+1) mod Space = 0
              and then
              (Left+1) mod (Space*2) = Space
              and then
              (for all K in A'Range =>
                  (if K in A'First .. Left - Space
                     and then (K + 1) mod (2 * Space) = 0
                   then
                      A (K) = Copy2 (K) + Copy2 (K - Space)
                   else
                      A (K) = Copy2 (K))));

            Right     := Left + Space;
            A (Right) := A (Left) + A (Right);
            Left      := Left + Space * 2;
         end loop;
         Space := Space * 2;
      end loop;
      Output_Space := Space;
   end Upsweep;

   procedure Downsweep
     (Ghost : Input; A : in out Input; Input_Space : in Positive)
   is
      Space : Natural := Input_Space;
      Left  : Natural;
      Right : Natural;
      Temp  : Integer;
      Copy1 : Input;
      Copy2 : Input;
   begin
      A (A'Last) := 0;
      Space      := Space / 2;

      Copy1 := A;
      while Space > 0 loop
         pragma Assert (Space <= Input_Space / 2
           and then All_Elements_In (A, (4 / Space) * 8 * Maximum));

         Right := Space * 2 - 1;

         Copy2 := A;
         while Right < A'Length loop
            pragma Assert
              (for all K in A'Range =>
                  (if K in A'First .. Right - Space * 2 then
                     (if (K + 1) mod (2 * Space) = 0 then
                         A (K) = Copy2 (K) + Copy2 (K - Space)
                      elsif (K + 1) mod Space = 0 then
                         A (K) = Copy2 (K + Space)
                      else
                         A (K) = Copy2 (K))));

            Left      := Right - Space;
            Temp      := A (Right);
            A (Right) := A (Left) + A(Right);
            A (Left)  := Temp;
            Right     := Right + Space * 2;
         end loop;
         Space := Space / 2;
      end loop;
   end Downsweep;

end PrefixSum;
