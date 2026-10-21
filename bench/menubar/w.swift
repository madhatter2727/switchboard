import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String:Any]]
for w in l where (w["kCGWindowLayer"] as? Int) == 25 { let b=w["kCGWindowBounds"] as! [String:Any]; print(w["kCGWindowOwnerName"] ?? "", b["X"] ?? "", b["Width"] ?? "") }
