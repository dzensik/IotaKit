//
//  Iota.swift
//  iotakit
//
//  Created by Pasquale Ambrosini on 10/01/2018.
//

import Foundation

public class Iota {
	
	fileprivate(set) var address: String = ""
	public var debug = false
	fileprivate var localPoW: IotaLocalPoW? = PearlDiverLocalPoW()
	fileprivate let APIServices: IotaAPIServices.Type = IotaAPIService.self
	
	public init(prefersHTTPS: Bool = false, _ onReady: @escaping (Iota?) -> Void) {
		IotaNodeSelector.bestNode({ (nodes) in
			var add = nodes.first!.fullAddress
			if prefersHTTPS {
				for n in nodes {
					if !n.address.hasPrefix("https") {
						continue
					}
					add = n.fullAddress
					break
				}
			}
			self.address = add
			onReady(self)
		}) { (error) in
			onReady(nil)
		}
	}
	
	public init(node: String, port: UInt) {
		self.address = node.appending(":").appending(String(port))
	}
	
	public init(node: String) {
		self.address = node
	}
	
	public func nodeInfo(_ success: @escaping ([String: Any]) -> Void, error: @escaping (Error) -> Void) {
		APIServices.nodeInfo(nodeAddress: self.address, success, error)
	}
	
	public func balances(addresses: [String], _ success: @escaping (_ balances: [String: Int]) -> Void, error: @escaping (Error) -> Void) {
		APIServices.balances(nodeAddress: self.address, addresses: addresses, success, error)
	}
	
	public func findTransactions(addresses: [String], _ success: @escaping (_ hashes: [String]) -> Void, error: @escaping (Error) -> Void) {
		APIServices.findTransactions(nodeAddress: self.address, addresses: addresses, success, error)
	}
	
	public func trytes(hashes: [String], _ success: @escaping (_ trytes: [IotaTransaction]) -> Void, error: @escaping (Error) -> Void) {
		APIServices.trytes(nodeAddress: self.address, hashes: hashes, success, error)
	}
	
	public func accountData(seed: String, _ success: @escaping (_ account: IotaAccount) -> Void, error: @escaping (Error) -> Void) {
		
		var account = IotaAccount()
		var index = 0
		var lastAddress = ""
		
		func findBalances() {
			IotaDebug("Getting balances")
			self.balances(addresses: account.addresses, { (balances) in
				self.IotaDebug("Got balances \(balances.count)")
				account.balance = balances.reduce(0, { (r, e) -> Int in return r+e.value })
				success(account)
			}) { (e) in
				error(e)
			}
		}
		
		func findTransactions() {
			let address = IotaAPIUtils.newAddress(seed: seed, security: 2, index: index, checksum: false)
			IotaDebug("Getting transactions")
			APIServices.findTransactions(nodeAddress: self.address, addresses: [address], { (hashes) in
				self.IotaDebug("Got transactions \(hashes.count)")
				if hashes.count == 0 {
					findBalances()
				}else{
					account.addresses.append(address)
					DispatchQueue.main.async {
						index += 1
						findTransactions()
					}
				}
			}) { (e) in
				error(e)
			}
		}
		
		findTransactions()
	}
	
	public func attachToTangle(seed: String, index: Int, security: Int = 2, _ success: @escaping (_ transfer: IotaTransaction) -> Void, error: @escaping (Error) -> Void) {
		let address = IotaAPIUtils.newAddress(seed: seed, security: security, index: index, checksum: false)
		self.attachToTangle(seed: seed, address: address, security: security, success, error: error)
	}
	
	public func sendTransfers(seed: String, security: Int = 2, depth: Int = 10, minWeightMagnitude: Int = 14, transfers: [IotaTransfer], inputs: [String]?, remainderAddress: String, _ success: @escaping (_ transactions: [IotaTransaction]) -> Void, error: @escaping (Error) -> Void) {
		
		guard let trytes = self.prepareTransfers(seed: seed, security: security, transfers: transfers, remainder: remainderAddress, inputs: inputs, validateInputs: false) else {
			error(IotaAPIError("Error preparing transfers"))
			return
		}
		IotaDebug("Sending trytes")
		self.sendTrytes(trytes: trytes, { (trxs) in
			success(trxs)
		}, error: error)
	}
	
	internal func attachToTangle(seed: String, address: String, security: Int = 2, _ success: @escaping (_ transfer: IotaTransaction) -> Void, error: @escaping (Error) -> Void) {
		let transfers = [IotaTransfer(address: address, value: 0, timestamp: nil, hash: nil, persistence: false)]
		self.sendTransfers(seed: seed, security: security, transfers: transfers, inputs: nil, remainderAddress: "", { (txs) in
			guard let tx1 = txs.first else {
				error(IotaAPIError("Network error, tx not received"))
				return
			}
			success(tx1)
		}, error: error)
	}
	
	internal func sendTrytes(trytes: [String], depth: Int = 10, minWeightMagnitude: Int = 14, _ success: @escaping (_ transactions: [IotaTransaction]) -> Void, error: @escaping (Error) -> Void) {
		
		//4
		func toTxs(trytes t: [String]) {
			IotaDebug("Converting to transactions")
			let trx = t.map { IotaTransaction(trytes: $0) }
			success(trx)
		}
		
		//3
		func store(trytes t: [String]) {
			IotaDebug("Storing trytes")
			APIServices.storeTransactions(nodeAddress: self.address, trytes: t, {
				toTxs(trytes: t)
			}, error)
		}
		
		//2
		func broadcast(trytes t: [String]) {
			IotaDebug("Broadcasting trytes")
			APIServices.broadcastTransactions(nodeAddress: self.address, trytes: t, {
				store(trytes: t)
			}, error)
		}
		
		//1
		func attach(trunkTx: String, branchTx: String) {
			IotaDebug("Attaching to tangle (PoW)")
			self.attachToTangle(trunkTx: trunkTx, branchTx: branchTx, minWeightMagnitude: minWeightMagnitude, trytes: trytes, { (t) in
				broadcast(trytes: t)
			}, error: error)
		}
		
		//0
		IotaDebug("Getting TXs to approve")
		APIServices.transactionsToApprove(nodeAddress: self.address, depth: depth, { (txs) in
			attach(trunkTx: txs.trunkTx, branchTx: txs.branchTx)
		}) { (e) in
			error(e)
		}
	}
	
	internal func prepareTransfers(seed: String, security: Int, transfers: [IotaTransfer], remainder: String?, inputs: [String]?, validateInputs: Bool) -> [String]? {
		var bundle = IotaBundle()
		var signatureFragment: [String] = []
		var totalValue: UInt = 0
		var tag = ""
		
		IotaDebug("Preparing transfers")
		for var transfer in transfers {
			if IotaChecksum.isValidChecksum(address: transfer.address) {
				transfer.address = IotaChecksum.removeChecksum(address: transfer.address)!
			}
			
			var signatureMessageLength = 1
			
			if transfer.message.count > IotaConstants.messageLength {
				signatureMessageLength += transfer.message.count / IotaConstants.messageLength
				
				var msgCopy = transfer.message
				
				while !msgCopy.isEmpty {
					var fragment = msgCopy.substring(from: 0, to: IotaConstants.messageLength)
					msgCopy = msgCopy.substring(from: IotaConstants.messageLength, to: msgCopy.count)
					fragment.rightPad(count: IotaConstants.messageLength, character: "9")
					signatureFragment.append(fragment)
				}
			}else {
				var fragment = transfer.message
				fragment.rightPad(count: IotaConstants.messageLength, character: "9")
				signatureFragment.append(fragment)
			}
			
			tag = transfer.tag
			tag.rightPad(count: IotaConstants.tagLength, character: "9")
			
			let timestamp = floor(Date().timeIntervalSince1970)
			bundle.addEntry(signatureMessageLength: signatureMessageLength, address: transfer.address, value: transfer.value, tag: tag, timestamp: UInt(timestamp))
			totalValue += transfer.value
		}
		
		if totalValue != 0 {
			//TODO
		}else{
			bundle.finalize(customCurl: nil)
			bundle.addTrytes(signatureFragments: signatureFragment)
			
			let trxb = bundle.transactions
			var bundleTrytes: [String] = []
			
			for trx in trxb {
				bundleTrytes.append(trx.trytes)
			}
			bundleTrytes.reverse()
			return bundleTrytes
		}
		return nil
	}
	
	
	
	internal func attachToTangle(trunkTx: String, branchTx: String, minWeightMagnitude: Int, trytes: [String], _ success: @escaping (_ trytes: [String]) -> Void, error: @escaping (Error) -> Void) {
		if let localPow = self.localPoW {
			var resultTrytes: [String] = []
			var previousTransaction: String! = nil
			
			DispatchQueue.global(qos: .userInitiated).async {
				for t in trytes {
					var txn = IotaTransaction(trytes: t)
					txn.trunkTransaction = previousTransaction == nil ? trunkTx : previousTransaction
					txn.branchTransaction = previousTransaction == nil ? branchTx : trunkTx
					if txn.tag.isEmpty /*|| Set(txn.tag).isSubset(of: ["9"])*/ {
						//txn.tag = txn.obsoleteTag
						txn.tag = "".rightPadded(count: 27, character: "9")
					}
					txn.attachmentTimestamp = UInt(Date().timeIntervalSince1970*1000)
					txn.attachmentTimestampLowerBound = 0
					txn.attachmentTimestampUpperBound = 3_812_798_742_493
					resultTrytes.append(localPow.performPoW(trytes: txn.trytes, minWeightMagnitude: minWeightMagnitude))
					previousTransaction = IotaTransaction(trytes: resultTrytes.last!).hash
				}
				success(resultTrytes)
			}
		}else{
			APIServices.attachToTangle(nodeAddress: self.address, trunkTx: trunkTx, branchTx: branchTx, minWeightMagnitude: minWeightMagnitude, trytes: trytes, { (resultTrytes) in
				success(resultTrytes)
			}, { (e) in
				error(e)
			})
		}
	}
	
	fileprivate func IotaDebug(_ items: Any, separator: String = " ", terminator: String = "\n") {
		if self.debug { print("[IotaKit] \(items)", separator: separator, terminator: terminator) }
	}
}
