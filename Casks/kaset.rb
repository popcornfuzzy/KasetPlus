cask "kaset" do
  version "0.8"
  sha256 "981106634241c3cd66023c2101ca2ddf5d6a03842385681afeff6d76016be490"

  url "https://github.com/popcornfuzzy/kaset/releases/download/v#{version}/kaset-v#{version}.dmg"
  name "Kaset"
  desc "Native YouTube Music client"
  homepage "https://github.com/popcornfuzzy/kaset"

  auto_updates false
  depends_on macos: ">= :tahoe"

  app "Kaset.app"

  postflight do
    system_command "/usr/bin/xattr", args: ["-cr", "#{appdir}/Kaset.app"], sudo: false
  end

  zap trash: [
    "~/Library/Application Support/Kaset",
    "~/Library/Caches/com.popcornfuzzy.Kaset",
    "~/Library/Preferences/com.popcornfuzzy.Kaset.plist",
    "~/Library/Saved Application State/com.popcornfuzzy.Kaset.savedState",
    "~/Library/WebKit/com.popcornfuzzy.Kaset",
  ]
end
