// Suppose "synchronized(x) {...}" is desugared into
// "x.lock() ... x.unlock()" in the frontend.

property "Object.notifyAll should be called only when the lock is held"
  start -> unheld: L.new()
  unheld -> error: l.notifyAll()
  unheld -> held: l.lock()
  held -> unheld: l.unlock()

class Object
  Unit lock()
  Unit unlock()
  Unit notifyAll()
  Unit wait();  not really needed

main
  var Object o := new
  o.lock()
  o.notifyAll(); OK
  o.unlock()
  o.notifyAll(); NOK
