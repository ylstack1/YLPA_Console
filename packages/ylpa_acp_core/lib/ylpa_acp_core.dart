/// YLPA ACP Core — manifest-driven agent-type catalog + generic ACP client.
///
/// One backend, every ACP agent: agent differences are data (manifests),
/// never code. See README.md for the architecture.
library;

export 'src/manifest/config_field.dart';
export 'src/manifest/agent_type_manifest.dart';
export 'src/manifest/agent_instance.dart';
export 'src/manifest/agent_catalog.dart';

export 'src/acp/acp_transport.dart';
export 'src/acp/jsonrpc.dart';
export 'src/acp/acp_models.dart';
export 'src/acp/acp_client.dart';
