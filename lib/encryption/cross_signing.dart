/*
 *   Famedly Matrix SDK
 *   Copyright (C) 2020, 2021 Famedly GmbH
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU Affero General Public License as
 *   published by the Free Software Foundation, either version 3 of the
 *   License, or (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU Affero General Public License for more details.
 *
 *   You should have received a copy of the GNU Affero General Public License
 *   along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:olm/olm.dart' as olm;

import '../famedlysdk.dart';
import 'encryption.dart';

class CrossSigning {
  final Encryption encryption;
  Client get client => encryption.client;
  CrossSigning(this.encryption) {
    encryption.ssss.setValidator(EventTypes.CrossSigningSelfSigning,
        (String secret) async {
      final keyObj = olm.PkSigning();
      try {
        return keyObj.init_with_seed(base64.decode(secret)) ==
            client.userDeviceKeys[client.userID].selfSigningKey.ed25519Key;
      } catch (_) {
        return false;
      } finally {
        keyObj.free();
      }
    });
    encryption.ssss.setValidator(EventTypes.CrossSigningUserSigning,
        (String secret) async {
      final keyObj = olm.PkSigning();
      try {
        return keyObj.init_with_seed(base64.decode(secret)) ==
            client.userDeviceKeys[client.userID].userSigningKey.ed25519Key;
      } catch (_) {
        return false;
      } finally {
        keyObj.free();
      }
    });
  }

  bool get enabled =>
      encryption.ssss.isSecret(EventTypes.CrossSigningSelfSigning) &&
      encryption.ssss.isSecret(EventTypes.CrossSigningUserSigning) &&
      encryption.ssss.isSecret(EventTypes.CrossSigningMasterKey);

  Future<bool> isCached() async {
    if (!enabled) {
      return false;
    }
    return (await encryption.ssss
                .getCached(EventTypes.CrossSigningSelfSigning)) !=
            null &&
        (await encryption.ssss.getCached(EventTypes.CrossSigningUserSigning)) !=
            null;
  }

  Future<void> selfSign(
      {String passphrase, String recoveryKey, String keyOrPassphrase}) async {
    final handle = encryption.ssss.open(EventTypes.CrossSigningMasterKey);
    await handle.unlock(
        passphrase: passphrase,
        recoveryKey: recoveryKey,
        keyOrPassphrase: keyOrPassphrase);
    await handle.maybeCacheAll();
    final masterPrivateKey =
        base64.decode(await handle.getStored(EventTypes.CrossSigningMasterKey));
    final keyObj = olm.PkSigning();
    String masterPubkey;
    try {
      masterPubkey = keyObj.init_with_seed(masterPrivateKey);
    } finally {
      keyObj.free();
    }
    if (masterPubkey == null ||
        !client.userDeviceKeys.containsKey(client.userID) ||
        !client.userDeviceKeys[client.userID].deviceKeys
            .containsKey(client.deviceID)) {
      throw Exception('Master or user keys not found');
    }
    final masterKey = client.userDeviceKeys[client.userID].masterKey;
    if (masterKey == null || masterKey.ed25519Key != masterPubkey) {
      throw Exception('Master pubkey key doesn\'t match');
    }
    // master key is valid, set it to verified
    await masterKey.setVerified(true, false);
    // and now sign both our own key and our master key
    await sign([
      masterKey,
      client.userDeviceKeys[client.userID].deviceKeys[client.deviceID]
    ]);
  }

  bool signable(List<SignableKey> keys) {
    for (final key in keys) {
      if (key is CrossSigningKey && key.usage.contains('master')) {
        return true;
      }
      if (key.userId == client.userID &&
          (key is DeviceKeys) &&
          key.identifier != client.deviceID) {
        return true;
      }
    }
    return false;
  }

  Future<void> sign(List<SignableKey> keys) async {
    Uint8List selfSigningKey;
    Uint8List userSigningKey;
    final signedKeys = <MatrixSignableKey>[];
    final addSignature =
        (SignableKey key, SignableKey signedWith, String signature) {
      if (key == null || signedWith == null || signature == null) {
        return;
      }
      final signedKey = key.cloneForSigning();
      signedKey.signatures[signedWith.userId] = <String, String>{};
      signedKey.signatures[signedWith.userId]
          ['ed25519:${signedWith.identifier}'] = signature;
      signedKeys.add(signedKey);
    };
    for (final key in keys) {
      if (key.userId == client.userID) {
        // we are singing a key of ourself
        if (key is CrossSigningKey) {
          if (key.usage.contains('master')) {
            // okay, we'll sign our own master key
            final signature =
                encryption.olmManager.signString(key.signingContent);
            addSignature(
                key,
                client
                    .userDeviceKeys[client.userID].deviceKeys[client.deviceID],
                signature);
          }
          // we don't care about signing other cross-signing keys
        } else {
          // okay, we'll sign a device key with our self signing key
          selfSigningKey ??= base64.decode(await encryption.ssss
                  .getCached(EventTypes.CrossSigningSelfSigning) ??
              '');
          if (selfSigningKey.isNotEmpty) {
            final signature = _sign(key.signingContent, selfSigningKey);
            addSignature(key,
                client.userDeviceKeys[client.userID].selfSigningKey, signature);
          }
        }
      } else if (key is CrossSigningKey && key.usage.contains('master')) {
        // we are signing someone elses master key
        userSigningKey ??= base64.decode(await encryption.ssss
                .getCached(EventTypes.CrossSigningUserSigning) ??
            '');
        if (userSigningKey.isNotEmpty) {
          final signature = _sign(key.signingContent, userSigningKey);
          addSignature(key, client.userDeviceKeys[client.userID].userSigningKey,
              signature);
        }
      }
    }
    if (signedKeys.isNotEmpty) {
      // post our new keys!
      await client.uploadKeySignatures(signedKeys);
    }
  }

  String _sign(String canonicalJson, Uint8List key) {
    final keyObj = olm.PkSigning();
    try {
      keyObj.init_with_seed(key);
      return keyObj.sign(canonicalJson);
    } finally {
      keyObj.free();
    }
  }
}
