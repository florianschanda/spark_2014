package Tests_Async_Writers
with Abstract_State => (State_With_Async_Writers
                        with External => (Async_Writers, Effective_Reads))
is
   pragma Elaborate_Body;
end Tests_Async_Writers;
