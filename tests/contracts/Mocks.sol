// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal ERC-20 mock for Wake tests. Supports mint/burn, no access control.
contract MockToken {
    string public name;
    string public symbol;
    uint8  public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory _name, string memory _symbol) {
        name   = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply    += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ALLOWANCE");
            allowance[from][msg.sender] = allowed - amount;
        }
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "BAL");
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

interface IERC20Pull {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Mock GPv2VaultRelayer — a solver settlement pulls the executor's escrow via the
/// standing approval. In production GPv2Settlement calls the relayer; here a test acts as
/// the solver and calls `pull` directly.
contract MockRelayer {
    function pull(address token, address from, address to, uint256 amount) external {
        IERC20Pull(token).transferFrom(from, to, amount);
    }
}

/// @notice Mock GPv2Settlement — exposes the PreSign + vaultRelayer surface a contract uses.
/// The executor presigns each slice's orderUid (it never calls settle, which is onlySolver).
contract MockSettlement {
    address public vaultRelayer;
    mapping(bytes32 => bool) public presigned;
    uint256 public presignCount;

    constructor() {
        vaultRelayer = address(new MockRelayer());
    }

    function setPreSignature(bytes calldata uid, bool signed) external {
        bytes32 k = keccak256(uid);
        bool was = presigned[k];
        presigned[k] = signed;
        if (signed && !was) presignCount++;
        if (!signed && was) presignCount--;
    }
}
