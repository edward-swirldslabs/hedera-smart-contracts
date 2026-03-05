// SPDX-License-Identifier: Apache-2.0

function deriveConnectorId(ethersLib, prefix, ownerKey, localLedgerId, remoteLedgerId) {
  return ethersLib.keccak256(
    ethersLib.solidityPacked(
      ['string', 'bytes32', 'bytes32', 'bytes32'],
      [prefix, ownerKey, localLedgerId, remoteLedgerId]
    )
  );
}

function deriveConnectorIds(ethersLib, sourceLedgerId, destinationLedgerId) {
  const ownerKeys = [1, 2, 3].map((n) =>
    ethersLib.keccak256(ethersLib.toUtf8Bytes(`connector-owner-${n}`))
  );

  const source = ownerKeys.map((ownerKey) =>
    deriveConnectorId(ethersLib, 'src', ownerKey, sourceLedgerId, destinationLedgerId)
  );
  const destination = ownerKeys.map((ownerKey) =>
    deriveConnectorId(ethersLib, 'dst', ownerKey, destinationLedgerId, sourceLedgerId)
  );

  return {
    ownerKeys,
    source,
    destination,
  };
}

module.exports = {
  deriveConnectorId,
  deriveConnectorIds,
};
