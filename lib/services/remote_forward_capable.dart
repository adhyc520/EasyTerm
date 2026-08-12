import 'browser_gateway.dart';
import 'local_port_forwarder.dart';

/// Port-forwarding capability (SSH only).
abstract class RemoteForwardCapable {
  Future<LocalPortForwarder> openLocalForward(
    String remoteHost,
    int remotePort, {
    int? localPort,
  });

  Future<void> releaseLocalForward(LocalPortForwarder? fwd);

  Future<BrowserGateway> getOrCreateGateway();

  List<LocalPortForwarder> get desktopForwards;
}
