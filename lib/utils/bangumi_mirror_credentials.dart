// Bangumi mirror API credentials for the search signature flow.
// Release/PR CI injects them via --dart-define=KAZUMI_APPID / KAZUMI_KEY.
const _envId = String.fromEnvironment('KAZUMI_APPID');
const _envValue = String.fromEnvironment('KAZUMI_KEY');

const Map<String, String> bangumiMirrorCredentials = {
  'id': (_envId == '') ? 'kazumi-hh47hcih6xfodp50' : _envId,
  'value': (_envValue == '') ? 'EKlABDVRMb8g5OkCH78SL14riZU4zmkR8TvRmu3GORIeJcdQ' : _envValue,
};
