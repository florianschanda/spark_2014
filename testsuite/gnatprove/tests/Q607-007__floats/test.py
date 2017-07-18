from test_support import *
prove_all(steps=70000, prover=["cvc4", "z3"], codepeer=True, no_fail=True)
