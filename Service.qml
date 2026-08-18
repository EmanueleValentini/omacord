import QtQuick

// The shell mounts one of these per enabled service plugin, for the whole
// session. Making the bridge the service means one connection to Discord no
// matter how many monitors carry a bar — a second RPC connection would show
// up as a second authorization in Discord's own list.
//
// The bar widget falls back to a local Rpc instance when this is not
// loaded, so the plugin still works with only the widget enabled.
Rpc {
  // Injected by the shell's service loader; unused here, but declared so
  // the assignments land somewhere rather than being dropped.
  property var shell: null
  property var manifest: null
  property var barWidgetRegistry: null
  property var pluginRegistry: null
  property string omarchyPath: ""
}
