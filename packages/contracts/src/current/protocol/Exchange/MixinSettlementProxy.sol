/*

  Copyright 2017 ZeroEx Intl.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity ^0.4.19;

import "./mixins/MSettlement.sol";
import { IToken_v1 as IToken } from "../../interfaces/IToken_v1.sol";
import { ITokenTransferProxy_v1 as ITokenTransferProxy } from "../../interfaces/ITokenTransferProxy_v1.sol";
import "./LibPartialAmount.sol";

/// @dev Provides MixinSettlement
contract MixinSettlementProxy is
    MSettlement,
    LibPartialAmount
{

    uint16 constant public EXTERNAL_QUERY_GAS_LIMIT = 4999;    // Changes to state require at least 5000 gas

    ITokenTransferProxy TRANSFER_PROXY;
    IToken ZRX_TOKEN;
    
    function transferProxy()
        external view
        returns (ITokenTransferProxy)
    {
        return TRANSFER_PROXY;
    }
    
    function zrxToken()
        external view
        returns (IToken)
    {
        return ZRX_TOKEN;
    }
    
    function MixinSettlementProxy(
        ITokenTransferProxy proxyContract,
        IToken zrxToken
    )
        public
    {
      ZRX_TOKEN = zrxToken;
      TRANSFER_PROXY = proxyContract;
    }
    
    function settleOrder(
          Order order,
          address taker,
          uint filledTakerTokenAmount)
          internal
          returns (
            uint filledMakerTokenAmount,
            uint paidMakerFee,
            uint paidTakerFee
          )
    {
        filledMakerTokenAmount = getPartialAmount(filledTakerTokenAmount, order.takerTokenAmount, order.makerTokenAmount);
        require(TRANSFER_PROXY.transferFrom(
            order.makerToken,
            order.maker,
            taker,
            filledMakerTokenAmount
        ));
        require(TRANSFER_PROXY.transferFrom(
            order.takerToken,
            taker,
            order.maker,
            filledTakerTokenAmount
        ));
        if (order.feeRecipient != address(0)) {
            if (order.makerFee > 0) {
                paidMakerFee = getPartialAmount(filledTakerTokenAmount, order.takerTokenAmount, order.makerFee);
                require(TRANSFER_PROXY.transferFrom(
                    ZRX_TOKEN,
                    order.maker,
                    order.feeRecipient,
                    paidMakerFee
                ));
            }
            if (order.takerFee > 0) {
                paidTakerFee = getPartialAmount(filledTakerTokenAmount, order.takerTokenAmount, order.takerFee);
                require(TRANSFER_PROXY.transferFrom(
                    ZRX_TOKEN,
                    taker,
                    order.feeRecipient,
                    paidTakerFee
                ));
            }
        }
    }

    /// @dev Checks if any order transfers will fail.
    /// @param order Order struct of params that will be checked.
    /// @param fillTakerTokenAmount Desired amount of takerToken to fill.
    /// @return Predicted result of transfers.
    function isTransferable(Order order, uint fillTakerTokenAmount)
        internal
        constant  // The called token contracts may attempt to change state, but will not be able to due to gas limits on getBalance and getAllowance.
        returns (bool)
    {
        address taker = msg.sender;
        uint fillMakerTokenAmount = getPartialAmount(fillTakerTokenAmount, order.takerTokenAmount, order.makerTokenAmount);

        if (order.feeRecipient != address(0)) {
            bool isMakerTokenZRX = order.makerToken == address(ZRX_TOKEN);
            bool isTakerTokenZRX = order.takerToken == address(ZRX_TOKEN);
            uint paidMakerFee = getPartialAmount(fillTakerTokenAmount, order.takerTokenAmount, order.makerFee);
            uint paidTakerFee = getPartialAmount(fillTakerTokenAmount, order.takerTokenAmount, order.takerFee);
            uint requiredMakerZRX = isMakerTokenZRX ? safeAdd(fillMakerTokenAmount, paidMakerFee) : paidMakerFee;
            uint requiredTakerZRX = isTakerTokenZRX ? safeAdd(fillTakerTokenAmount, paidTakerFee) : paidTakerFee;

            if (   getBalance(ZRX_TOKEN, order.maker) < requiredMakerZRX
                || getAllowance(ZRX_TOKEN, order.maker) < requiredMakerZRX
                || getBalance(ZRX_TOKEN, taker) < requiredTakerZRX
                || getAllowance(ZRX_TOKEN, taker) < requiredTakerZRX
            ) return false;

            if (!isMakerTokenZRX && (   getBalance(order.makerToken, order.maker) < fillMakerTokenAmount // Don't double check makerToken if ZRX
                                     || getAllowance(order.makerToken, order.maker) < fillMakerTokenAmount)
            ) return false;
            if (!isTakerTokenZRX && (   getBalance(order.takerToken, taker) < fillTakerTokenAmount // Don't double check takerToken if ZRX
                                     || getAllowance(order.takerToken, taker) < fillTakerTokenAmount)
            ) return false;
        } else if (   getBalance(order.makerToken, order.maker) < fillMakerTokenAmount
                   || getAllowance(order.makerToken, order.maker) < fillMakerTokenAmount
                   || getBalance(order.takerToken, taker) < fillTakerTokenAmount
                   || getAllowance(order.takerToken, taker) < fillTakerTokenAmount
        ) return false;

        return true;
    }

    /// @dev Get token balance of an address.
    /// @param token Address of token.
    /// @param owner Address of owner.
    /// @return Token balance of owner.
    function getBalance(address token, address owner)
        internal
        constant  // The called token contract may attempt to change state, but will not be able to due to an added gas limit.
        returns (uint)
    {
        return IToken(token).balanceOf.gas(EXTERNAL_QUERY_GAS_LIMIT)(owner); // Limit gas to prevent reentrancy
    }

    /// @dev Get allowance of token given to TokenTransferProxy by an address.
    /// @param token Address of token.
    /// @param owner Address of owner.
    /// @return Allowance of token given to TokenTransferProxy by owner.
    function getAllowance(address token, address owner)
        internal
        constant  // The called token contract may attempt to change state, but will not be able to due to an added gas limit.
        returns (uint)
    {
        return IToken(token).allowance.gas(EXTERNAL_QUERY_GAS_LIMIT)(owner, TRANSFER_PROXY); // Limit gas to prevent reentrancy
    }
}
