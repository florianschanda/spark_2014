from test_support import *

prove_all(codepeer=True, steps=10000, prover=["cvc4", "z3"])
