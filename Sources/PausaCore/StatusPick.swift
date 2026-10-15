/// Which text the menu status line shows while auto-paused (PR #6 review): the PauseSource
/// line whenever there is one; the old 「已暂停：…」 / deferral text only without a source.
public enum StatusPick {
  public static func line(source: String?, autoStatus: String?, reason: String?) -> String? {
    source ?? autoStatus ?? reason
  }
}
