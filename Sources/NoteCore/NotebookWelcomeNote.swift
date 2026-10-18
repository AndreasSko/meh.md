import Foundation

/// The first note of a new notebook. Every device ships these exact bytes, so
/// welcome notes created offline on several devices share one Automerge
/// history and merge on first sync. Never change them: different text needs a
/// new ID, since disconnected histories cannot merge.
public enum NotebookWelcomeNote {
    public static let id = UUID(uuidString: "CCB4E987-B2CC-47EB-B509-0B6D1476D403")!
    public static let name = "Hi •_•"
    static let heads: Set<String> = [
        "2abdae288ffada0c3db8de164cba97ca1eae7052a631c2471fd659dbff463eba",
    ]

    static var snapshot: NoteSnapshot {
        NoteSnapshot(data: Data(base64Encoded: base64)!, heads: heads, noteID: id)
    }

    private static let base64 = """
        hW9Kg3NJoeAAtwYBEKUakwTAkUKKrY7eeOUn53sBKr2uKI/62gw9uN4WTLqXyh6ucFKmMcJH
        H9ZZ2/9GProGAQIDAhMDIwZAAlYCDAEFAgURBRMIFTMhAyMJNANCB1YXX9AEgAEDfwB/AX/8
        Bn+A9crWBn8AfwcABfcGAAAF9wYDAAb2BgAABX4ABPUGAXsJY3JlYXRlZEF0Cm1vZGlmaWVk
        QXQGbm90ZUlEDXNjaGVtYVZlcnNpb24EdGV4dAD3BvwGAH37BgGFefkGAQX3BgQBfwT3BgEC
        aX3GBBMAtwUWfzYDFn82sQEWfzYJFlVSQW7UQBAU131F3wKWbQVYErIHpOwmIZFAiUhAQhFS
        Zu1e7+DxtDXTXuPbHrnDCzjwB3hOXkLPrBOJi2W5y9VV1bX9/uvPz+k2PheL+fT06PVhNn+x
        WGTTw9N5Nn+1f5Ttzw9Onk8PD06m+y+fXOw1MFDnYKWdZ7DEmMNpqTmFGrFNgRwweQ8N5pNJ
        g+u8KePEg2bwumkNzqA1Slt4r1xdUm8jiwdlS/CDLYDXiuFrJ/Q9udrn8Dks3IFGgKOuWu+E
        6IWhrkxlDviNnQJVFNRZDkoMVdru9MlPCF41GImALDSdYS1yoMSNLtCngBu0QKuV0VZcLdbK
        VhicuAojf0FWZgV7sXYMK+yFVNvKi2NoqUZQHHGtQ+87h7PJJINb+ALXPMgeFfyU0GteRzUr
        co1iFgZYKpfDZYikmEGSnD1OkgQkqYBmIhNgI+XN0CLc3d7eheUiuJb8SHC7oB5Ql604Gq8g
        lh8gO8c5XOwZA0sM/C7c6y1RGfhqS30U/wELtDxm3yuJUfGoppWk4EwblANdjRrJCkyuIsFv
        ooZ3ZKssxgFP5R5OV2vOCsmwfiZxBNpg96OXcDzcoLRDMYpnwT5+vra6bZGTJI+Ceqc5fqcV
        izk1LtR1KOIG3QDy8FrcelaDD/Elyf32t7Deb//K+6dxfK49kxsC7+QNXOXXkgcsO234ITHh
        Dq7GeratzJXpA2mvLGM5g0Zb3SiTPnY5hcqhZBR6msMxLHVkS+XHhqTRS3JyVdn0f8PPSa4p
        0JJkk/QiepKL56L5BxzbUkj95B/8BgAA
        """.replacingOccurrences(of: "\n", with: "")
}
