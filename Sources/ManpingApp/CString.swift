extension String {
  init(nullTerminatedCString buffer: [CChar]) {
    self.init(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}