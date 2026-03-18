namespace Kgd;

/// <summary>
/// RGB color with 16-bit per channel precision.
/// </summary>
public record Color(int R = 0, int G = 0, int B = 0);

/// <summary>
/// Describes a logical position for a placement.
/// </summary>
public record Anchor(
    string Type = "absolute",
    string PaneId = "",
    int WinId = 0,
    int BufLine = 0,
    int Row = 0,
    int Col = 0)
{
    /// <summary>
    /// Serialize to a dictionary, omitting zero-valued fields (except Type which is always included).
    /// </summary>
    public Dictionary<string, object> ToDict()
    {
        var d = new Dictionary<string, object> { ["type"] = Type };
        if (!string.IsNullOrEmpty(PaneId))
            d["pane_id"] = PaneId;
        if (WinId != 0)
            d["win_id"] = WinId;
        if (BufLine != 0)
            d["buf_line"] = BufLine;
        if (Row != 0)
            d["row"] = Row;
        if (Col != 0)
            d["col"] = Col;
        return d;
    }
}

/// <summary>
/// Describes a single active placement.
/// </summary>
public record PlacementInfo(
    int PlacementId = 0,
    string ClientId = "",
    int Handle = 0,
    bool Visible = false,
    int Row = 0,
    int Col = 0);

/// <summary>
/// Daemon status information.
/// </summary>
public record StatusResult(
    int Clients = 0,
    int Placements = 0,
    int Images = 0,
    int Cols = 0,
    int Rows = 0);

/// <summary>
/// Options for connecting to the kgd daemon.
/// </summary>
public record Options(
    string SocketPath = "",
    string SessionId = "",
    string ClientType = "",
    string Label = "",
    bool AutoLaunch = true);

/// <summary>
/// Optional source-crop and z-index parameters for <see cref="KgdClient.PlaceAsync"/>.
/// </summary>
public record PlaceOpts(
    int SrcX = 0,
    int SrcY = 0,
    int SrcW = 0,
    int SrcH = 0,
    int ZIndex = 0);
