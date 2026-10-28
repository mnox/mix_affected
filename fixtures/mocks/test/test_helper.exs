# Mocks are defined at runtime, as most projects do it: the mock module has no
# source file, only the behaviour it is for does.
Mox.defmock(Mocks.MockClock, for: Mocks.Clock)
Application.put_env(:mocks, :clock, Mocks.MockClock)
ExUnit.start()
