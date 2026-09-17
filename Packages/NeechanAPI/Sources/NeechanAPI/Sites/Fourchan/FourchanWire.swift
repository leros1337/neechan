import Foundation

/// 4chan's JSON, exactly as it arrives.
///
/// Separate from the neutral models because almost every field is absent when
/// empty — a plain text reply carries only `no`, `now`, `name`, `com`, `time`
/// and `resto` — and because the names collide with 2ch's meaning more often
/// than they agree with it. The mapping lives next door in `FourchanMapping`.
enum FourchanWire {
    /// One post. The same shape is used for an OP, a reply, a catalog row and
    /// an index preview; which fields are present is what differs.
    struct Post: Decodable {
        let no: Int
        let resto: Int?
        let time: Int?
        let lastModified: Int?
        let now: String?
        let name: String?
        let trip: String?
        let id: String?
        let capcode: String?
        let country: String?
        let countryName: String?
        let boardFlag: String?
        let flagName: String?
        let sub: String?
        let com: String?

        // Attachment. Present together, or not at all.
        let tim: Int?
        let filename: String?
        let ext: String?
        let fsize: Int?
        let md5: String?
        let w: Int?
        let h: Int?
        let tnW: Int?
        let tnH: Int?
        let fileDeleted: Int?
        let spoiler: Int?

        // Thread-level, on an OP only.
        let sticky: Int?
        let closed: Int?
        let archived: Int?
        let replies: Int?
        let images: Int?
        let uniqueIPs: Int?

        enum CodingKeys: String, CodingKey {
            case no, resto, time, now, name, trip, id, capcode, country, sub, com
            case tim, filename, ext, fsize, md5, w, h, spoiler
            case sticky, closed, archived, replies, images
            case lastModified = "last_modified"
            case countryName = "country_name"
            case boardFlag = "board_flag"
            case flagName = "flag_name"
            case tnW = "tn_w"
            case tnH = "tn_h"
            case fileDeleted = "filedeleted"
            case uniqueIPs = "unique_ips"
        }
    }

    /// `GET /boards.json`
    struct BoardsResponse: Decodable {
        let boards: [Board]
    }

    struct Board: Decodable {
        let board: String
        let title: String?
        let wsBoard: Int?
        let perPage: Int?
        let pages: Int?
        /// Bytes, despite the documentation saying kilobytes.
        let maxFilesize: Int?
        let maxWebmFilesize: Int?
        let maxCommentChars: Int?
        let bumpLimit: Int?
        let metaDescription: String?
        let isArchived: Int?
        let spoilers: Int?
        let countryFlags: Int?
        let userIDs: Int?
        let oekaki: Int?
        let codeTags: Int?
        let mathTags: Int?
        let textOnly: Int?
        let forcedAnon: Int?
        /// Flag code to flag name, on the two boards that have them.
        let boardFlags: [String: String]?

        enum CodingKeys: String, CodingKey {
            case board, title, pages, spoilers, oekaki
            case wsBoard = "ws_board"
            case perPage = "per_page"
            case maxFilesize = "max_filesize"
            case maxWebmFilesize = "max_webm_filesize"
            case maxCommentChars = "max_comment_chars"
            case bumpLimit = "bump_limit"
            case metaDescription = "meta_description"
            case isArchived = "is_archived"
            case countryFlags = "country_flags"
            case userIDs = "user_ids"
            case codeTags = "code_tags"
            case mathTags = "math_tags"
            case textOnly = "text_only"
            case forcedAnon = "forced_anon"
            case boardFlags = "board_flags"
        }
    }

    /// `GET /{board}/catalog.json` — a bare array of pages.
    struct CatalogPage: Decodable {
        let page: Int?
        let threads: [CatalogThread]
    }

    /// An OP with the counters the catalog adds to it.
    struct CatalogThread: Decodable {
        let post: Post
        let replies: Int?
        let images: Int?
        let lastReplies: [Post]?

        enum CodingKeys: String, CodingKey {
            case replies, images
            case lastReplies = "last_replies"
        }

        init(from decoder: any Decoder) throws {
            // The catalog row *is* a post, with a few extra keys alongside.
            post = try Post(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            replies = try container.decodeIfPresent(Int.self, forKey: .replies)
            images = try container.decodeIfPresent(Int.self, forKey: .images)
            lastReplies = try container.decodeIfPresent([Post].self, forKey: .lastReplies)
        }
    }

    /// `GET /{board}/{page}.json`
    struct IndexPage: Decodable {
        let threads: [ThreadContainer]
    }

    struct ThreadContainer: Decodable {
        let posts: [Post]
    }

    /// `GET /{board}/threads.json` — a bare array of pages.
    struct ThreadListPage: Decodable {
        let page: Int?
        let threads: [ThreadStub]
    }

    /// What the watcher reads: a thread's number and how many replies it holds.
    struct ThreadStub: Decodable {
        let no: Int
        let lastModified: Int?
        let replies: Int?

        enum CodingKeys: String, CodingKey {
            case no, replies
            case lastModified = "last_modified"
        }
    }
}
