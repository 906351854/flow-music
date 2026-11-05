import Foundation
import CommonCrypto
import CryptoKit

/// 网易 eapi 请求加密。
///
/// 算法（固定 key 的 AES-128-ECB，输出大写 hex）：
///   1. digest = md5("nobody" + apiPath + "use" + body + "md5forencrypt")
///   2. plain  = apiPath + "-36cd479b6b5-" + body + "-36cd479b6b5-" + digest
///   3. params = AES-128-ECB(plain, key: "e82ckenh8dichen8")  →  大写 hex
///
/// 注意：请求打到 `/eapi/xxx`，但摘要里参与计算的是 `/api/xxx`。
enum RequestCrypto {

    static let eapiKey = "e82ckenh8dichen8"

    /// - Parameters:
    ///   - apiPath: 形如 `/api/song/enhance/player/url/v1`
    ///   - payloadJSON: 已经序列化好的紧凑 JSON 字符串
    static func eapi(apiPath: String, payloadJSON: String) -> [String: String] {
        let message = "nobody\(apiPath)use\(payloadJSON)md5forencrypt"
        let digest = Insecure.MD5.hash(data: Data(message.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let plain = "\(apiPath)-36cd479b6b5-\(payloadJSON)-36cd479b6b5-\(digest)"
        guard let cipher = aes128ECB(Data(plain.utf8), key: eapiKey) else { return [:] }
        return ["params": cipher.map { String(format: "%02X", $0) }.joined()]
    }

    /// AES-128-ECB + PKCS7。ECB 不需要 IV，这也是 eapi 与老 weapi(CBC) 的区别。
    private static func aes128ECB(_ data: Data, key: String) -> Data? {
        let keyData = Data(key.utf8)
        guard keyData.count == kCCKeySizeAES128 else { return nil }

        var out = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0

        let status = out.withUnsafeMutableBytes { outPtr -> Int32 in
            data.withUnsafeBytes { dataPtr -> Int32 in
                keyData.withUnsafeBytes { keyPtr -> Int32 in
                    guard let outBase = outPtr.baseAddress,
                          let dataBase = dataPtr.baseAddress,
                          let keyBase = keyPtr.baseAddress else { return Int32(kCCParamError) }
                    return Int32(CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                        keyBase, keyData.count, nil,
                        dataBase, data.count,
                        outBase, outPtr.count, &written
                    ))
                }
            }
        }

        guard status == kCCSuccess else {
            NSLog("[3YE] AES-128-ECB 失败，status=\(status)")
            return nil
        }
        return out.prefix(written)
    }
}
