import Foundation

/// Phonetic Latin spelling for reading lyrics, preserving existing English.
/// Urdu/Shahmukhi omit short vowels: common words have readable spellings;
/// unfamiliar words use a conservative transliteration rather than translation.
enum LyricsRomanizer {
    private static let cache = NSCache<NSString, NSString>()

    static func romanize(_ text: String) -> String {
        if let cached = cache.object(forKey: text as NSString) { return cached as String }
        // Tokenise by script runs instead of whitespace, preserving punctuation,
        // parentheses, newlines and English inside a mixed-language source word.
        var result = ""
        var run = ""
        var script: Int?
        func flush() {
            guard !run.isEmpty else { return }
            let normalized = run.precomposedStringWithCompatibilityMapping
            if let common = commonWords[normalized] { result += common }
            else if script == 1 || script == 2 { result += romanizeIndic(normalized) }
            else if script == 3 { result += romanizeUrdu(normalized) }
            else { result += run }
            run = ""
        }
        for scalar in text.unicodeScalars {
            let kind: Int
            switch scalar.value {
            case 0x0900...0x097F: kind = scalar.properties.isAlphabetic || scalar.properties.generalCategory == .nonspacingMark ? 1 : 0
            case 0x0A00...0x0A7F: kind = scalar.properties.isAlphabetic || scalar.properties.generalCategory == .nonspacingMark ? 2 : 0
            case 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
                kind = scalar.properties.isAlphabetic || scalar.properties.generalCategory == .nonspacingMark ? 3 : 0
            case 0x200C, 0x200D: kind = script ?? 0
            default: kind = 0
            }
            if script != kind { flush(); script = kind }
            run += String(scalar)
        }
        flush()
        cache.countLimit = 1500
        cache.setObject(result as NSString, forKey: text as NSString)
        return result
    }

    private static func romanizeIndic(_ text: String) -> String {
        let scalars = Array(text.precomposedStringWithCanonicalMapping.unicodeScalars)
        var result = ""
        var inherentVowel = false
        var doubleNext = false
        for (index, scalar) in scalars.enumerated() {
            let value = scalar.value
            // The Devanagari and Gurmukhi blocks share the ISCII positions.
            let offset = Int(value) - (value >= 0x0A00 ? 0x0A00 : 0x0900)
            if let consonant = consonants[offset] {
                if inherentVowel { result += "a" }
                let nukta = index + 1 < scalars.count && [0x093C, 0x0A3C].contains(scalars[index + 1].value)
                let sound = nukta ? (nuktaConsonants[offset] ?? consonant) : consonant
                result += (doubleNext ? sound : "") + sound
                doubleNext = false
                inherentVowel = true
            } else if let vowel = vowels[offset] {
                if inherentVowel { result += "a" }
                result += vowel
                inherentVowel = false
            } else if let vowel = vowelMarks[offset] {
                result += vowel
                inherentVowel = false
            } else if offset == 0x4D { // virama suppresses the inherent vowel
                inherentVowel = false
            } else if offset == 0x71 && value >= 0x0A00 { // Punjabi addak
                if inherentVowel { result += "a" }
                inherentVowel = false
                doubleNext = true
            } else if [0x01, 0x02, 0x70].contains(offset) {
                if inherentVowel { result += "a"; inherentVowel = false }
                let following = scalars.dropFirst(index + 1).first {
                    let v = Int($0.value) - (value >= 0x0A00 ? 0x0A00 : 0x0900)
                    return consonants[v] != nil
                }
                let nextOffset = following.map { Int($0.value) - (value >= 0x0A00 ? 0x0A00 : 0x0900) }
                result += nextOffset.map { (0x2A...0x2E).contains($0) ? "m" : "n" } ?? "n"
            } else if offset == 0x03 {
                result += "h"
            } else if offset == 0x3C || value == 0x200C || value == 0x200D {
                continue
            } else {
                if inherentVowel { result += "a"; inherentVowel = false }
                result += String(scalar)
            }
        }
        // Hindi and Punjabi generally drop the word-final inherent schwa.
        // Drop a medial schwa before a final explicitly vowelled syllable:
        // supanaa → supnaa, sohanaa → sohnaa, apanaa → apnaa.
        return result.replacingOccurrences(
            of: #"([aeiou])((?:[kgcjtdpb]h|[bcdfghjklmnpqrstvwxyz]))a((?:[kgcjtdpb]h|[bcdfghjklmnpqrstvwxyz]))([aeiou]+[n]?)$"#,
            with: "$1$2$3$4", options: .regularExpression)
    }

    private static func romanizeUrdu(_ text: String) -> String {
        let normalized = text.precomposedStringWithCompatibilityMapping
        var result = ""
        for scalar in normalized.unicodeScalars {
            if let sound = urduLetters[scalar] { result += sound }
            else if scalar.value == 0x0651 {
                if let last = result.last { result.append(last) }
            } else if scalar.value != 0x200C && scalar.value != 0x200D {
                result += String(scalar)
            }
        }
        return result
    }

    private static let consonants: [Int: String] = [
        0x15:"k",0x16:"kh",0x17:"g",0x18:"gh",0x19:"ng",0x1A:"ch",0x1B:"chh",0x1C:"j",0x1D:"jh",0x1E:"ny",
        0x1F:"t",0x20:"th",0x21:"d",0x22:"dh",0x23:"n",0x24:"t",0x25:"th",0x26:"d",0x27:"dh",0x28:"n",
        0x2A:"p",0x2B:"ph",0x2C:"b",0x2D:"bh",0x2E:"m",0x2F:"y",0x30:"r",0x31:"r",0x32:"l",0x33:"l",
        0x35:"v",0x36:"sh",0x37:"sh",0x38:"s",0x39:"h",0x58:"q",0x59:"kh",0x5A:"g",0x5B:"z",0x5C:"r",0x5D:"rh",0x5E:"f"
    ]
    private static let nuktaConsonants = [0x15:"q",0x16:"kh",0x17:"g",0x1C:"z",0x21:"r",0x22:"rh",0x2B:"f"]
    private static let vowels = [0x05:"a",0x06:"aa",0x07:"i",0x08:"ee",0x09:"u",0x0A:"oo",0x0B:"ri",0x0F:"e",0x10:"ai",0x13:"o",0x14:"au"]
    private static let vowelMarks = [0x3E:"aa",0x3F:"i",0x40:"ee",0x41:"u",0x42:"oo",0x43:"ri",0x47:"e",0x48:"ai",0x4B:"o",0x4C:"au"]
    private static let urduLetters: [Unicode.Scalar: String] = [
        "ا":"a","آ":"aa","أ":"a","إ":"i","ب":"b","پ":"p","ت":"t","ٹ":"t","ث":"s","ج":"j","چ":"ch","ح":"h","خ":"kh",
        "د":"d","ڈ":"d","ذ":"z","ر":"r","ڑ":"r","ز":"z","ژ":"zh","س":"s","ش":"sh","ص":"s","ض":"z","ط":"t","ظ":"z",
        "ع":"a","غ":"gh","ف":"f","ق":"q","ک":"k","ك":"k","گ":"g","ل":"l","م":"m","ن":"n","ں":"n","و":"o",
        "ؤ":"o","ہ":"h","ھ":"h","ه":"h","ۃ":"h","ة":"h","ی":"ee","ي":"ee","ے":"e","ئ":"y","ء":"'",
        "َ":"a","ِ":"i","ُ":"u","ْ":"","ٰ":"aa","ً":"an","ٍ":"in","ٌ":"un","ـ":"","۔":".","،":",","؟":"?"
    ]
    private static let commonWords: [String: String] = [
        "ਪੰਜਾਬੀ":"punjabi","ਪੰਜਾਬ":"punjab","ਪੱਗ":"pagg","ਦਿਲ":"dil","ਪਿਆਰ":"pyaar","ਨਹੀਂ":"nahi","ਮੈਂ":"main","ਤੂੰ":"tu",
        "ਮੇਰਾ":"mera","ਮੇਰੀ":"meri","ਮੇਰੇ":"mere","ਤੇਰਾ":"tera","ਤੇਰੀ":"teri","ਤੇਰੇ":"tere","ਤੈਨੂੰ":"tainu","ਮੈਨੂੰ":"mainu",
        "ਸਾਨੂੰ":"saanu","ਤੁਸੀਂ":"tusi","ਅੱਖ":"akh","ਅੱਖਾਂ":"akhaan","ਜੱਟ":"jatt","ਜੱਟੀ":"jatti","ਵਿੱਚ":"vich","ਨਾਲ":"naal",
        "ਹੈ":"hai","ਨੇ":"ne","ਤੇ":"te","ਦਾ":"da","ਦੀ":"di","ਦੇ":"de","ਨੀ":"ni","ਇੱਕ":"ikk","ਕੀ":"ki","ਹੋ":"ho",
        "ਕੁੜੀ":"kudi","ਮੁੰਡਾ":"munda","ਸੋਹਣੀ":"sohni","ਰੱਬ":"rabb","ਰਾਤ":"raat","ਜਾਨ":"jaan","ਯਾਰ":"yaar",
        "ज्ञान":"gyaan","तू":"tu","तुझे":"tujhe","मुझे":"mujhe","तेरी":"teri","आँखें":"aankhein","आंखें":"aankhein",
        "साँसें":"saansein","सांसें":"saansein","ज़िंदगी":"zindagi","जिंदगी":"zindagi","हुआ":"hua","हुई":"hui","रहा":"raha","रही":"rahi",
        "रहे":"rahe","अंबर":"ambar","अम्बर":"ambar","चाँद":"chaand","चांद":"chaand","दुनिया":"duniya","ख्वाब":"khwaab",
        "दिल":"dil","प्यार":"pyaar","नहीं":"nahi","मैं":"main","हूँ":"hoon","है":"hai","हैं":"hain","तेरा":"tera",
        "तेरे":"tere","मेरा":"mera","मेरी":"meri","मेरे":"mere","तुम":"tum","हम":"hum","ये":"ye","यह":"yeh","वो":"woh",
        "क्या":"kya","क्यों":"kyun","में":"mein","और":"aur","इश्क":"ishq","इश्क़":"ishq","मोहब्बत":"mohabbat","तुम्हें":"tumhe",
        "تم":"tum","میں":"main","میرا":"mera","میری":"meri","میرے":"mere","تیرا":"tera","تیری":"teri","تیرے":"tere","دل":"dil",
        "ہے":"hai","ہیں":"hain","ہوں":"hoon","نہیں":"nahi","پیار":"pyaar","عشق":"ishq","محبت":"mohabbat","جان":"jaan",
        "کی":"ki","کے":"ke","کا":"ka","کو":"ko","سے":"se","اور":"aur","یہ":"yeh","وہ":"woh","ہم":"hum","تو":"tu",
        "توں":"tu","مینوں":"mainu","تینوں":"tainu","نوں":"nu","وچ":"vich","نال":"naal","دا":"da","دی":"di","دے":"de",
        "یار":"yaar","خدا":"khuda","کیا":"kya","کیوں":"kyun","بھی":"bhi","کبھی":"kabhi","تمہیں":"tumhe","مجھے":"mujhe",
        "رات":"raat","بات":"baat","دن":"din","زندگی":"zindagi","ہو":"ho","ایک":"ek","ہوگا":"hoga","تھا":"tha","تھی":"thi"
    ]
}
