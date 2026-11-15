import Foundation

/// Period site icons for link cards: the favicons popular sites used around 2012 (Twitter's blue
/// bird, YouTube's red tube…), shown in place of whatever the site uses today.
///
/// The pictures ship inside the app (`RetroIcons/<name>.png`); nothing is fetched at run time.
/// For now they are the sites' original favicons, kept out of the repository (see the folder's
/// README); icons drawn for this app are to replace them. Where a site's picture is missing,
/// its card keeps the icon it has today.
enum RetroIcons {
    /// Icon name → the hosts it stands for. A host matches itself and its subdomains.
    private static let sites: [(icon: String, hosts: [String])] = [
        ("twitter", ["twitter.com", "x.com", "t.co"]),
        ("youtube", ["youtube.com", "youtu.be", "youtube-nocookie.com"]),
        ("facebook", ["facebook.com", "fb.com", "fb.me", "fb.watch"]),
        ("instagram", ["instagram.com", "instagr.am"]),
        ("googlemaps", ["maps.google.com", "maps.app.goo.gl", "goo.gl"]),
        ("gmail", ["mail.google.com", "gmail.com"]),
        ("google", ["google.com", "g.co"]),
        ("wikipedia", ["wikipedia.org"]),
        ("amazon", ["amazon.com", "amzn.to", "a.co", "amzn.com"]),
        ("reddit", ["reddit.com", "redd.it"]),
        ("apple", ["apple.com", "apple.co"]),
        ("nytimes", ["nytimes.com", "nyti.ms"]),
        ("linkedin", ["linkedin.com", "lnkd.in"]),
        ("github", ["github.com"]),
        ("tumblr", ["tumblr.com"]),
        ("pinterest", ["pinterest.com", "pin.it"]),
        ("flickr", ["flickr.com", "flic.kr"]),
        ("vimeo", ["vimeo.com"]),
        ("yelp", ["yelp.com"]),
        ("ebay", ["ebay.com"]),
        ("netflix", ["netflix.com"]),
        ("spotify", ["spotify.com", "spotify.link"]),
        ("imdb", ["imdb.com"]),
        ("cnn", ["cnn.com"]),
        ("bbc", ["bbc.co.uk", "bbc.com"]),
        ("espn", ["espn.com", "espn.go.com"]),
        ("paypal", ["paypal.com", "paypal.me"]),
        ("dropbox", ["dropbox.com"]),
        ("soundcloud", ["soundcloud.com"]),
        ("twitch", ["twitch.tv"]),
        ("craigslist", ["craigslist.org"]),
        ("yahoo", ["yahoo.com"]),
        ("wordpress", ["wordpress.com"]),
        ("stackoverflow", ["stackoverflow.com"]),
        ("washingtonpost", ["washingtonpost.com", "wapo.st"]),
        ("etsy", ["etsy.com", "etsy.me"]),
        ("imgur", ["imgur.com"]),
        ("airbnb", ["airbnb.com"]),
        ("guardian", ["theguardian.com", "guardian.co.uk"]),
        ("wsj", ["wsj.com"]),
        ("npr", ["npr.org"]),
        ("huffpost", ["huffpost.com", "huffingtonpost.com"]),
        ("buzzfeed", ["buzzfeed.com"]),
        ("walmart", ["walmart.com"]),
        ("target", ["target.com"]),
    ]

    /// Inside the built app, or beside the binary when run straight from `swift build`.
    private static let directory: URL? = {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("RetroIcons")) }
        if let binary = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            let bundle = binary.appendingPathComponent("LionMessages_LionMessages.bundle")
            candidates.append(bundle.appendingPathComponent("RetroIcons"))
            candidates.append(bundle.appendingPathComponent("Contents/Resources/RetroIcons"))
        }
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }()

    /// Icons that are actually in the folder (a missing file just means no period icon).
    private static let available: [String: URL] = {
        guard let directory else { return [:] }
        var out: [String: URL] = [:]
        for site in sites {
            let file = directory.appendingPathComponent(site.icon + ".png")
            if FileManager.default.fileExists(atPath: file.path) { out[site.icon] = file }
        }
        return out
    }()

    /// The period icon for a link's site, if there is one.
    static func icon(for url: URL) -> (name: String, file: URL)? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        // The list is ordered so a specific host (maps.google.com) wins over its parent.
        for site in sites where site.hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return available[site.icon].map { (site.icon, $0) }
        }
        return nil
    }
}
