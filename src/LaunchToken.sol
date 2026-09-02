// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { ERC20PermitBase } from "./ERC20PermitBase.sol";
import { LaunchPoolConfig } from "./libraries/LaunchPoolConfig.sol";

/// @notice Fixed-supply token created by TokenLaunchpad. The creator can update only
/// presentation metadata; supply and ownership mechanics are immutable.
/// @dev Approvals may also be granted by EIP-2612 signature, under a domain named by `name()`.
contract LaunchToken is ERC20PermitBase {
    uint256 private constant TOKEN_NAME_MIN_LENGTH = 2;
    uint256 private constant TOKEN_NAME_MAX_LENGTH = 48;
    uint256 private constant TOKEN_SYMBOL_MIN_LENGTH = 2;
    uint256 private constant TOKEN_SYMBOL_MAX_LENGTH = 10;
    uint256 private constant METADATA_URL_MAX_LENGTH = 2_048;
    uint256 private constant TWITTER_HANDLE_MAX_LENGTH = 15;
    uint256 private constant TELEGRAM_HANDLE_MAX_LENGTH = 32;

    address public immutable creator;
    string public imageUrl;
    string public websiteUrl;
    string public twitterHandle;
    string public telegramHandle;

    event MetadataUpdated(
        string imageUrl, string websiteUrl, string twitterHandle, string telegramHandle
    );

    error InvalidAddress();
    error InvalidTokenName();
    error InvalidTokenSymbol();
    error MetadataUrlTooLong();
    error InvalidTwitterHandle();
    error InvalidTelegramHandle();
    error OnlyCreator();

    constructor(
        string memory name_,
        string memory symbol_,
        string memory imageUrl_,
        string memory websiteUrl_,
        string memory twitterHandle_,
        string memory telegramHandle_,
        address creator_,
        address initialHolder_
    ) ERC20(name_, symbol_) {
        if (creator_ == address(0) || initialHolder_ == address(0)) {
            revert InvalidAddress();
        }
        uint256 nameLength = bytes(name_).length;
        if (nameLength < TOKEN_NAME_MIN_LENGTH || nameLength > TOKEN_NAME_MAX_LENGTH) {
            revert InvalidTokenName();
        }
        uint256 symbolLength = bytes(symbol_).length;
        if (symbolLength < TOKEN_SYMBOL_MIN_LENGTH || symbolLength > TOKEN_SYMBOL_MAX_LENGTH) {
            revert InvalidTokenSymbol();
        }

        creator = creator_;
        _setMetadata(imageUrl_, websiteUrl_, twitterHandle_, telegramHandle_);
        _mint(initialHolder_, LaunchPoolConfig.TOKEN_SUPPLY);
    }

    function updateMetadata(
        string calldata imageUrl_,
        string calldata websiteUrl_,
        string calldata twitterHandle_,
        string calldata telegramHandle_
    ) external {
        if (msg.sender != creator) revert OnlyCreator();
        _setMetadata(imageUrl_, websiteUrl_, twitterHandle_, telegramHandle_);
        emit MetadataUpdated(imageUrl_, websiteUrl_, twitterHandle_, telegramHandle_);
    }

    function _setMetadata(
        string memory imageUrl_,
        string memory websiteUrl_,
        string memory twitterHandle_,
        string memory telegramHandle_
    ) private {
        if (
            bytes(imageUrl_).length > METADATA_URL_MAX_LENGTH
                || bytes(websiteUrl_).length > METADATA_URL_MAX_LENGTH
        ) {
            revert MetadataUrlTooLong();
        }
        if (!_isValidHandle(twitterHandle_, TWITTER_HANDLE_MAX_LENGTH)) {
            revert InvalidTwitterHandle();
        }
        if (!_isValidHandle(telegramHandle_, TELEGRAM_HANDLE_MAX_LENGTH)) {
            revert InvalidTelegramHandle();
        }

        imageUrl = imageUrl_;
        websiteUrl = websiteUrl_;
        twitterHandle = twitterHandle_;
        telegramHandle = telegramHandle_;
    }

    function _isValidHandle(string memory handle, uint256 maximumLength)
        private
        pure
        returns (bool)
    {
        bytes memory value = bytes(handle);
        if (value.length > maximumLength) return false;

        for (uint256 i; i < value.length; ++i) {
            bytes1 character = value[i];
            if (
                (character < 0x61 || character > 0x7a) && (character < 0x30 || character > 0x39)
                    && character != 0x5f
            ) {
                return false;
            }
        }
        return true;
    }
}
