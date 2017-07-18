from test_support import *

prove_all(prover=["cvc4", "z3"], codepeer=True, no_fail=True, opt=["--warnings=off"])
