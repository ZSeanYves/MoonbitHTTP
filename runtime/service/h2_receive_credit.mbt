///|
/// Outstanding DATA belongs either to a consumer or to terminal cleanup.
/// Claim bytes before any asynchronous window write so reset cannot refund
/// them again while that write is suspended.
priv struct H2ReceiveCredit {
  mut outstanding : Int
  mut retired : Bool
}

///|
fn H2ReceiveCredit::new() -> H2ReceiveCredit {
  { outstanding: 0, retired: false, }
}

///|
fn H2ReceiveCredit::consume(self : H2ReceiveCredit, amount : Int) -> Int {
  if self.retired {
    return 0
  }
  self.outstanding -= amount
  amount
}

///|
fn H2ReceiveCredit::retire(self : H2ReceiveCredit) -> Int {
  let amount = self.outstanding
  self.outstanding = 0
  self.retired = true
  amount
}
