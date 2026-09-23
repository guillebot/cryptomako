namespace CryptoMako.App;

/// <summary>
/// Soft Explorer CfAPI viewer surface. Lock disconnects the sync-root connection
/// (unmount viewer) without unregistering the root or wiping CredMan.
/// </summary>
public interface IExplorerViewer
{
    bool IsConnected { get; }
    void Disconnect();
}
