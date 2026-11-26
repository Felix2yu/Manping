// Adapted from BiliKernel 22fdf8ca (GPL-3.0), Copyright (c) Richasy.
import BiliProtocol
import Foundation
import GRPCCore
import SwiftProtobuf

// Upstream GrpcConfig field profile with one consistent installation-derived buvid. The upstream
// constant intentionally disagreed with its outer buvid; Manping does not mix those identities.
struct BiliRPCMetadata: Sendable {
  let installationID: String
  static func outerBuvid(_ id: String) -> String {
    let hash = Array(WBI.md5(id.replacingOccurrences(of: ":", with: "")))
    return "XY\(hash[2])\(hash[12])\(hash[22])" + String(hash)
  }
  func build(_ snapshot: AuthSnapshot, timestamp: Int64 = Int64(Date().timeIntervalSince1970))
    throws -> Metadata
  {
    var headers = Metadata()
    let token = snapshot.state == .appAuthorized ? snapshot.token : nil
    for (key, value) in snapshot.tokenHeaders { headers.addString(value, forKey: key) }
    headers.addString(
      "bili-universal/80200100 os/ios model/iPhone 14 Pro mobi_app/iphone_i osVer/16.6 network/2 Manping/1.0 (iPhone; iOS 16.6) grpc-swift-2/2.4.3",
      forKey: "user-agent")
    let buvid = Self.outerBuvid(installationID)
    var device = Bilibili_Metadata_Device_Device()
    device.appID = 1
    device.mobiApp = "iphone"
    device.build = 6_070_600
    device.channel = "bilibili140"
    device.buvid = buvid
    device.platform = "iphone"
    device.brand = "Apple"
    device.model = "iPhone 14 Pro"
    device.osver = "16.6"
    var metadata = Bilibili_Metadata_Metadata()
    metadata.accessKey = token?.accessToken ?? ""
    metadata.mobiApp = "iphone"
    metadata.build = 6_070_600
    metadata.channel = "bilibili140"
    metadata.buvid = buvid
    metadata.platform = "iphone"
    var fawkes = Bilibili_Metadata_Fawkes_FawkesReq()
    fawkes.appkey = "iphone"
    fawkes.env = "prod"
    var locale = Bilibili_Metadata_Locale_Locale()
    var ids = Bilibili_Metadata_Locale_LocaleIds()
    ids.language = "zh"
    ids.region = "CN"
    locale.cLocale = ids
    locale.sLocale = ids
    var network = Bilibili_Metadata_Network_Network()
    network.type = .wifi
    network.oid = "46007"
    func add<M: SwiftProtobuf.Message>(_ message: M, _ key: String) throws {
      // GRPCCore encodes raw binary as unpadded base64 exactly once on the HTTP/2 wire.
      headers.addBinary(Array(try message.serializedData()), forKey: key)
    }
    try add(device, "x-bili-device-bin")
    try add(fawkes, "x-bili-fawkes-req-bin")
    try add(locale, "x-bili-locale-bin")
    try add(metadata, "x-bili-metadata-bin")
    try add(network, "x-bili-network-bin")
    try add(Bilibili_Metadata_Restriction_Restriction(), "x-bili-restriction-bin")
    headers.addString("prod", forKey: "env")
    let mid = token?.mid ?? 0
    let key = Array("ad1va46a7lza".utf8)
    let eid =
      mid == 0
      ? ""
      : Data(String(mid).utf8.enumerated().map { $0.element ^ key[$0.offset % key.count] })
        .base64EncodedString().replacingOccurrences(of: "=", with: "")
    headers.addString(eid, forKey: "x-bili-aurora-eid")
    let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let trace =
      String(random.prefix(24))
      + [24, 16, 8].map { String(format: "%02x", (timestamp >> $0) & 255) }.joined()
      + String(random.suffix(2))
    headers.addString("\(trace):\(trace.suffix(16)):0:0", forKey: "x-bili-trace-id")
    headers.addString(buvid, forKey: "buvid")
    // Framing, TE, timeout and compression negotiation are owned by the native gRPC transport.
    return headers
  }
}
