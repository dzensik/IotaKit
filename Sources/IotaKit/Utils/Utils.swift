//
//  Utils.swift
//
//  Created by Pasquale Ambrosini on 07/01/18.
//

import Foundation

func arrayCopy<T>(src: [T], srcPos: Int, dest: inout [T], destPos: Int, length: Int) {
	dest[destPos..<(destPos+length)] = src[srcPos..<(srcPos+length)]
}

extension String {
	func substring(from: Int, to: Int) -> String {
		let start = index(startIndex, offsetBy: from)
		let end = index(start, offsetBy: to - from)
		return String(self[start ..< end])
	}
}