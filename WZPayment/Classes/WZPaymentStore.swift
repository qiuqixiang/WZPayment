//
//  WZSKPaymentStore.swift
//  WZSKPayment
//
//  Created by qiuqixiang on 2020/3/16.
//  Copyright © 2020 我主良缘. All rights reserved.
//

/* 支付流程：
  1：服务端获取订单编号 -> 2：向苹果请求产品id，并缓存 -> 3：向苹果发起购买 -> 4：上传支付凭证并校验
  丢单情况：
  1、APP外支付成功，未回调给APP，下次启动，会自动返回
  2、支付成功/支付失败APP已奔溃
  3、上传凭证失败
 */

import Foundation
import StoreKit
import KeychainAccess

// MAKR - 内购控制
public class WZPaymentStore: NSObject {
    
    weak var delegate: WZPaymentStoreDelegate?
    
    enum ErrorType: Int {
        case order = 1002
        case canPay  = 1003
       
        func error() -> Error {
            switch self {
            case .order:
                return NSError(domain: "订单id返回空，请联系客服", code: self.rawValue, userInfo: nil)
            case .canPay:
                return NSError(domain: "请到系统设置，开启苹果支付功能", code: self.rawValue, userInfo: nil)
            }
        }
    }
    
    /// 获取产品列表
    private lazy var productRequest: WZSKProduct = {
        return $0
    }(WZSKProduct())
    
    /// bundleId
    private var bundleId: String {
        return Bundle.main.infoDictionary?[kCFBundleIdentifierKey as String] as? String ?? "com.wz.apple.paymentid"
    }
    
    /// 钥匙串账号
    private var accessItem: String {
        return String(format: "com.applePay.%@", bundleId)
    }

    /// 获取钥匙串存储
    private lazy var keych: Keychain = {
        return Keychain(service: "WZStore_\(bundleId)")
    }()
    
    /// 获取沙河中凭证
    private var receiptDataStr: String {
        guard let url = Bundle.main.appStoreReceiptURL else {
            return ""
        }
        let receiptData = try? Data(contentsOf: url)
        let base64String = receiptData?.base64EncodedString(options: .endLineWithLineFeed) ?? ""
        return base64String
    }
    
    typealias PaySucessBlock = (_ transId: String, _ orderId: String, _ productId: String) -> Void
    typealias PayFailBlock = (_ error: Error) -> Void
    
    /// 购买成功回调可能包含l历史订单
    private var paySucessHandler: PaySucessBlock?

    /// 购买失败回调
    private var payFailHandler: PayFailBlock?
        
    init(cDlegate: WZPaymentStoreDelegate) {
        super.init()
        delegate = cDlegate
        SKPaymentQueue.default().add(self)
    }
    
    deinit {
        SKPaymentQueue.default().remove(self)
    }
    
    /// 开始下单
    /// - Parameters:
    ///   - productId: 苹果内购产品id
    ///   - tradeNoId: 订单编号
    func addPayment(productId: String, orderId: String, sucessHandler: PaySucessBlock?, failHandler: PayFailBlock?) {
        paySucessHandler = sucessHandler
        payFailHandler = failHandler
        
        /// 0: 检测订单id
        if productId.count == 0 || orderId.count == 0 {
            payFailHandler?(ErrorType.order.error())
            return
        }
        
        /// 1: 检测是否开启内购
        if !SKPaymentQueue.canMakePayments() {
            payFailHandler?(ErrorType.canPay.error())
            return
        }
        
        /// 2：检测是否有历史订单未完结，如果有，直接上传此订单
        if let model = getPayModel(productId: productId), model.transId.count > 0 {
            callBackPaySucess(transId: model.transId, orderId: model.orderId, productId: model.productId)
            return
        }
        
        /// 3：找苹果下单
        productRequest.startGetProduct(productId: productId, sucessHandler: { [weak self](product) in
            guard let self = self else { return }
            
            /// 保存钥匙串订单编号
            self.savePayInfoToKeychain(productId: productId, orderId: orderId, transid: "")
            let payment = SKPayment(product: product)
            SKPaymentQueue.default().add(payment)
        }) { [weak self](error) in
            guard let self = self else { return }
            self.callBackPayFail(error: error)
        }
    }
    
    /// 获取历史订单
    func restored() {
        for key in keych.allKeys() {
            
            if let model = getPayInfoFromKeychain(key: key),
                model.transId.count > 0 {
                callBackPaySucess(transId: model.transId, orderId: model.orderId, productId: model.productId)
            }
        }
    }
}

// MARK - 扩展
extension WZPaymentStore {
    
    /// 保存订单到钥匙串
    private func savePayInfoToKeychain(productId: String, orderId: String, transid: String) {
        
        let jsonData = try! JSONSerialization.data(withJSONObject: ["productId":productId,
                                                                    "orderId": orderId,
                                                                    "transId": transid], options: [])
        try? keych.set(jsonData, key: orderId)
    }
    
    /// 移除本地订单
    func remove(key: String) {
       try? keych.remove(key)
    }
    
    /// 支付成功回调
    private func callBackPaySucess(transId: String, orderId: String, productId: String) {
        if paySucessHandler != nil, orderId.count > 0 {
            paySucessHandler?(transId, orderId, productId)
            return
        }
        delegate?.paymentStore(strore: self, restore: transId, orderId: orderId, productId: productId)
    }
    
    /// 支付失败回调
    private func callBackPayFail(error: Error)  {
        payFailHandler?(error)
    }
    
    /// 从DB 获取缓存数据
    private func getPayInfoFromKeychain(key: String) -> WZSKModel? {
        
        guard let data =  try? keych.getData(key) else {
            return nil
        }
        return try? JSONDecoder().decode(WZSKModel.self, from: data)
    }
    
    /// 获取支付数据
    private func getPayModel(productId: String) -> WZSKModel? {
        
        for key in keych.allKeys() {
            
            if let model = getPayInfoFromKeychain(key: key),
                model.productId == productId,
                model.transId.count == 0 {
                return model
            }
        }
        return nil
    }
}

/// 系统代理
extension WZPaymentStore: SKPaymentTransactionObserver  {
    
    public func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
    
        /// 按照时间排序
        let tranList = transactions.sorted(by: { (a, b) -> Bool in
            return a.transactionDate?.compare(b.transactionDate!) == .orderedDescending
        })
    
        for tran in tranList {
            switch tran.transactionState {
            case .restored:
                SKPaymentQueue.default().finishTransaction(tran)
            case .failed:
                
                if let model = getPayModel(productId: tran.payment.productIdentifier), model.transId.count == 0 {
                    remove(key: model.orderId)
                }
                if let error = tran.error as NSError? {
                    let xx = SKError(_nsError: error)
                    callBackPayFail(error: xx.getError())
                }
                SKPaymentQueue.default().finishTransaction(tran)
            case .purchased:
                /// 是否订阅
//                let isRenew = tran.original == nil ? false : true;
                
                /// 判断是否正常下单逻辑
                ///1、 本地没有服务器订单编号，直接上报不再走缓存路线
                ///2、本地有苹果订单、返回的苹果订单跟db缓存订单对应不上，走直接上报
                ///3、db产品id跟苹果返回的不一致、走直接上报
                if let model = getPayModel(productId: tran.payment.productIdentifier), model.transId.count == 0 {
                    model.transId = tran.transactionIdentifier ?? ""
                    savePayInfoToKeychain(productId: model.productId, orderId: model.orderId, transid: model.transId)
                    callBackPaySucess(transId: model.transId, orderId: model.orderId, productId: model.productId)
                }
//                else{
//                    callBackPaySucess(transId: tran.transactionIdentifier ?? "", orderId: "", productId: tran.payment.productIdentifier)
//                }
                SKPaymentQueue.default().finishTransaction(tran)
            case .deferred:
                SKPaymentQueue.default().finishTransaction(tran)
            case .purchasing: break
            @unknown default: break
            }
        }
    }
}

// MARK - WZSKPaymentStoreDelegate
protocol WZPaymentStoreDelegate: class {
    
    /// 补单回调
    func paymentStore(strore: WZPaymentStore, restore transId: String, orderId: String, productId: String)
}


// MARK - 获取苹果产品id请求
final class WZSKProduct: NSObject, SKProductsRequestDelegate {
    
    typealias ProductSucessBlock = (_ products: SKProduct) -> Void
    typealias productFailBlock = (_ error: Error) -> Void
    
    /// 当前产品id列表
    public var sKProducts: [SKProduct] = []
    
    /// 成功请求数据
    private var productSucessHandler: ProductSucessBlock?
    
    /// 请求失败
    private var productFailHandler: productFailBlock?
    
    /// 请求类
    var productsRequest: SKProductsRequest?
    
    func startGetProduct(productId: String, sucessHandler: ProductSucessBlock?, failHandler: productFailBlock?) {
        productSucessHandler = sucessHandler
        productFailHandler = failHandler
        
        guard let product = getSKProduct(productId: productId) else {
            requestProducts(products: [productId])
            return
        }
        productSucessHandler?(product)
    }
    
    /// 获取产品列表
    func requestProducts(products: [String]) {
        
        let productArr: Array<String> = products
        let sets:Set<String> = NSSet.init(array: productArr) as! Set<String>
        productsRequest = SKProductsRequest(productIdentifiers: sets)
        productsRequest?.delegate = self
        productsRequest?.start()
    }
    
    /// SKProductsRequestDelegate
    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        if response.products.count == 0 {
            let err = NSError(domain: "未获取到该产品", code: 100020, userInfo: nil)
            productFailHandler?(err)
            return
        }
        sKProducts.append(contentsOf: response.products)
        productSucessHandler?(response.products.first!)
    }
    
    func request(_ request: SKRequest, didFailWithError error: Error) {
        productFailHandler?(error)
    }
    
    /// 获取产品下单Payment
    func getSKProduct(productId: String) -> SKProduct? {
        
        for product in sKProducts {
            if product.productIdentifier == productId {
                return product
            }
        }
        return nil
    }
}

// MARK - 数据模型
class WZSKModel: Codable {
    
    /// 苹果订单id
    var transId: String
    
    /// 服务器返回订单id
    var orderId: String
    
    /// 产品id
    var productId: String
}

// MARK - 错误
extension SKError {
    
    func getError() -> Error {
        switch self.code {
        case .unknown:
            return NSError(domain: "订单id返回空，请联系客服", code: self.code.rawValue, userInfo: nil)
        case .paymentCancelled:
            return NSError(domain: "购买失败，您取消了付款", code: self.code.rawValue, userInfo: nil)
        case .cloudServiceRevoked:
            return NSError(domain: "您已撤消使用此云服务的权限", code: self.code.rawValue, userInfo: nil)
        case .paymentInvalid:
            return NSError(domain: "App Store无法识别付款参数", code: self.code.rawValue, userInfo: nil)
        case .paymentNotAllowed:
            return NSError(domain: "请开启授权付款权限", code: self.code.rawValue, userInfo: nil)
        case .storeProductNotAvailable:
            return NSError(domain: "所请求的产品在商店中不可用。", code: self.code.rawValue, userInfo: nil)
        case .cloudServiceNetworkConnectionFailed:
            return NSError(domain: "设备无法连接到网络。", code: self.code.rawValue, userInfo: nil)
        default:
            return NSError(domain: "未知错误", code: self.code.rawValue, userInfo: nil)
        }
    }
}


