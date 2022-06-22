// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

//Bit-NFT-Marketplace is a marketplace where you as a seller can list your erc721 tokens 
//for sale either on cash and carry basis or on installmental basis.
//It is a platform where buyers can buy NFT in dribs and drabs.
//sellers sends their nft to the contract using its address and the tokenId where it is secured.
//At the end of the duration of the sale which is 40 days,the seller gets his ether while the buyer gets his NFT
//if the buyer defaults,he/she forfeits 10% of total ether sent(5% for the marketplace and 5% compensation to the seller)
//And the seller gets back his NFT while the buyer gets back his ether minus 10% of total.
//If it is an instant sale,the marketplace receive 5% of the NFT price otherwise all funds go to seller..

contract BitNFTMarketPlace is Ownable{
     using Counters for Counters.Counter;
    //Deriving agreementId from Counters library
    Counters.Counter public agreementId;

    //All events to be emitted
    event NewNFTListed(address nftContractAddress,uint nftTokenId,address indexed seller,uint price);
    event NftBought(uint nftTokenId, address indexed seller,address indexed buyer, uint price);
    event LastBitPaid(uint nftTokenId,address indexed seller, address buyer, bool debtPaid);
    event BitBuy(uint nftTokenId,address indexed seller, address buyer,uint price);
    event SellerClaim(uint nftTokenId,address indexed seller);
    event BuyerClaim(uint nftTokenId,address indexed buyer);
    event AgreementEnded(uint nftTokenId,address indexed sellerOrBuyer,bool saleEnded);


   
   //Modelling the agreement
    struct Agreements {
        address nftContractAddress;
        uint nftTokenId;
        address seller;
        uint agreementEndAt;
        bool saleEnded;
        uint price;
        bool onBit;
    }
    //mapping from agreementId => buyer => totalBitsPerBuyer
     mapping( uint => mapping(address => uint)) public totalBitsPerBuyer;

    //Mapping each agreement to its agreementId
    mapping(uint => Agreements) public agreements;

    //enum 
    enum Bits {
        FirstBits,
        SecondBits,
        ThirdBits,
        LastBits
    }

      Bits  public bitLevel;

    constructor () {        
    }

    modifier agreementEnded(uint _agreementId){ 
        Agreements storage agreement = agreements[_agreementId];       
        require(agreement.saleEnded == true && (block.timestamp >= agreement.agreementEndAt),"agreement duration has not ended");
        _;
    }
    modifier canBuy(uint _agreementId){ 
        Agreements storage agreement = agreements[_agreementId];       
        require(msg.sender != agreement.seller, "NFT owner cannot buy his NFT");
        require(msg.value == agreement.price, "Value sent must be equal to Nft price");
        _;
    }

    modifier atLastBit( Bits LastBit ) {
        require(bitLevel == LastBit,"All installments have not been paid"
    );
        _;
    }

    //ListToken function help list NFT with its token contract address,tokenId and a price.
    //NFT can be bought between now and the next 40 days otherwise,it has to be re-listed 
    function listToken(address _nftContractAddress, uint _nftTokenId, uint _price) 
        public payable returns (uint _agreementId) {
    //Approve before sending
        IERC721(_nftContractAddress).approve(msg.sender,_nftTokenId);
    //use openzepellin ERC721 safeTransferFrom function to transfer NFT token safely     
        IERC721(_nftContractAddress).safeTransferFrom(msg.sender, address(this), _nftTokenId);
    //update the agreementId of the NFT to be listed using Counters library
         uint currentId = agreementId.current();
        agreementId.increment();
    //Get an instance of the Agreements Struct and give it the current Id.
        Agreements storage agreement = agreements[currentId];
    // update each property of the agreement struct
        agreement.nftContractAddress = _nftContractAddress;
        agreement.nftTokenId = _nftTokenId;
        agreement.seller = msg.sender;
        agreement.saleEnded = false;
        agreement.price = _price;
        agreement.onBit = false;
    //The real agreement time is for 40 days but for testing purpose,we use 4 minutes
        agreement.agreementEndAt = block.timestamp + (1 * 4 minutes); 
    //check if the smart contract already got the NFT token
        bool contractGotToken =  IERC721(_nftContractAddress).ownerOf(_nftTokenId) == address(this) ? true : false;
        require(contractGotToken, "Untransfered token cannot be listed");
        emit NewNFTListed(_nftContractAddress,_nftTokenId,msg.sender, _price);  
        return currentId;             
    }

    //buyNow function is called when the buyer wishes to pay all the ether requested by the seller
    function buyNow(address _nftContractAddress,uint _agreementId,uint _nftTokenId,uint _price) public payable canBuy(_agreementId) returns(bool){
    //Get an instance of the Agreements Struct and give it the current Id.
        Agreements storage agreement = agreements[ _agreementId];
    //calculate commission
        uint commisionedValue = (_price * 95) / 100;
        uint  contractValue = (_price * 5) / 100;
    //Check if the token has not been partly paid for by another buyer
    require(agreement.onBit == false,"A buyer has partly paid for this token");
    //Prevent re-entrancy attack
        agreement.price = 0;
    //Buyer sends ether to the seller minus contract commission
        IERC721(agreement.nftContractAddress).transferFrom(msg.sender,agreement.seller,commisionedValue );
        (bool done, ) = payable(msg.sender).call{value: commisionedValue}("");
        require(done, "Cannot send ether to the seller");
    //Send contract commission in form of ether to the smart contract owner
        IERC721(agreement.nftContractAddress).transferFrom(msg.sender,Ownable.owner(), contractValue );
        (bool etherSent, ) = payable(msg.sender).call{value: contractValue}("");
        require(etherSent, "Cannot send ether to the contract owner");
   //Approve before sending
        IERC721(_nftContractAddress).approve(address(this),_nftTokenId);
    //Smart contract sends nft to the buyer
        IERC721(agreement.nftContractAddress).safeTransferFrom(address(this),msg.sender,_nftTokenId);
        (bool tokenSent, ) = payable(msg.sender).call{value: _nftTokenId}("");
        require(tokenSent, "Cannot send NFT to the buyer");
        agreement.onBit = false;
    //Emit the the info of the Nft bought to the frontend
        emit  NftBought(_nftTokenId,agreement.seller,msg.sender, _price);
        return agreement.saleEnded = true;
    }

    //BuyInBit function is called by buyers who intend to buy the NFT in installments.
    // Meanwhile a seller cannot buy his/her own token
    function buyInBit(uint _agreementId,uint _nftTokenId,uint _bit, Bits _bitLevel) public payable {
        Agreements storage agreement = agreements[_agreementId];
        require(msg.sender != agreement.seller, "NFT owner cannot buy his NFT");
        //require(msg.sender == IdAddress[_agreementId],"Another address has partly paid for this token");
    //Bit buyer sends his bit or part payment to the smart contract
        IERC721(agreement.nftContractAddress).transferFrom(msg.sender,address(this), _bit);
        (bool sent, ) = payable(msg.sender).call{value: _bit}("");
        require(sent, "Cannot send ether to smart contract");
        agreement.onBit = true;
        bitLevel = _bitLevel;
        totalBitsPerBuyer[_agreementId][msg.sender] += _bit;
        emit BitBuy(_nftTokenId,agreement.seller,msg.sender,agreement.price);
    }

    //This function is called by the buyer who wants to pay his last bits and get his nft to end the agreement
    function payLastBit(address _nftContractAddress,uint _agreementId,uint _nftTokenId,uint _lastBit, Bits _bitLevel) public payable agreementEnded(_agreementId) atLastBit(_bitLevel)
        returns (bool success){
        Agreements storage agreement = agreements[_agreementId];
    //Check if its not the seller buying. 
        require(msg.sender != agreement.seller, "NFT owner cannot buy his NFT");
    //Check if it is the same bit payer that is completing his payment.   
      //  require(msg.sender == totalBitsPerBuyer[_agreementId][_buyersAddress],"Another address has partly paid for this token");
    //The buyer sends the lastbit to the smart contract if these conditions are met.
        IERC721(agreement.nftContractAddress).transferFrom(msg.sender,address(this),_lastBit);
    //Check if totalbits is equal seller's price or agreement time has elapse.
        require(totalBitsPerBuyer[_agreementId][msg.sender] == agreement.price || block.timestamp >= agreement.agreementEndAt, "total bits paid is not equal to seller's price");
     //Check if the bitlevel is at the last, signalling last chunk paid.
        require(bitLevel == _bitLevel, "total bits paid is not equal to seller's price");
    //Get the balance the buyer has paid so far.    
         uint bal =  totalBitsPerBuyer[_agreementId][msg.sender];
    //calculate commission
        uint commisionedValue = (bal * 95) / 100;
        uint  contractValue = (bal * 5) / 100;
    //Prevent re-entrancy attack
        totalBitsPerBuyer[_agreementId][msg.sender] = 0;
    //Smart contract sends ether to the seller 
        IERC721(agreement.nftContractAddress).transferFrom(address(this),agreement.seller, commisionedValue );
        (bool sent, ) = payable(msg.sender).call{value:  commisionedValue}("");
        require(sent, "Cannot send ether to the seller");
    //Approve before sending
        IERC721(_nftContractAddress).approve(address(this),_nftTokenId);
    //Smart contract sends NFT to the buyer
        IERC721(agreement.nftContractAddress).safeTransferFrom(address(this),msg.sender, agreement.nftTokenId);
        (bool nftSent, ) = payable(msg.sender).call{value:agreement.nftTokenId }("");
        require(nftSent, "Could not send NFT token to the buyer");
    //Send contract commission in form of ether to the smart contract owner
        IERC721(agreement.nftContractAddress).transferFrom(address(this),Ownable.owner(), contractValue );
        (bool etherSent, ) = payable(msg.sender).call{value: contractValue}("");
        require(etherSent, "Cannot send ether to the contract owner");
        emit LastBitPaid(_nftTokenId,agreement.seller,msg.sender,success);
        emit AgreementEnded(_nftTokenId, agreement.seller, agreement.saleEnded);
        return (success);
    }

    //This function is used by the seller at the expiry of the installment agreement
    function sellerClaimNFT(address _nftContractAddress,uint _agreementId,uint _nftTokenId,Bits _bitLevel) external atLastBit(_bitLevel) {
        Agreements storage agreement = agreements[_agreementId];
        require(totalBitsPerBuyer[_agreementId][msg.sender] < agreement.price,"total payment made");
        require(agreement.saleEnded == false,"Agreement ended already");
        require(bitLevel != _bitLevel);
        require(block.timestamp >= agreement.agreementEndAt,"The agreement has not ended yet");
    //calculate seller's compensation   
        uint bal = totalBitsPerBuyer[_agreementId][msg.sender];
        uint compensationValue = (bal * 10) / 100;
    //Approve before sending
        IERC721(_nftContractAddress).approve(address(this),_nftTokenId); 
    //Smart contract sends token to the seller
        IERC721(agreement.nftContractAddress).transferFrom(address(this),msg.sender,_nftTokenId);
        (bool sentToken, ) = payable(msg.sender).call{value:_nftTokenId}("");
        require(sentToken, "Cannot send nftTokenId to the seller");
    //Prevent re-entrancy attack
        totalBitsPerBuyer[_agreementId][msg.sender] = 0;
        agreement.saleEnded == true;
    //Smart contract sends compensation ether to the seller
        IERC721(agreement.nftContractAddress).transferFrom(address(this),agreement.seller,compensationValue);
        (bool sent, ) = payable(msg.sender).call{value:compensationValue}("");
        require(sent, "Cannot send ether to the seller");
        emit SellerClaim( _nftTokenId, msg.sender);
        emit AgreementEnded(_nftTokenId, msg.sender,agreement.saleEnded);
    }

    //BuyerClaimFund function is used by the buyer to claim his nft when all installments are paid
    function buyerClaimFund(uint _agreementId,uint _nftTokenId,Bits _bitLevel) external  returns (bool success) {
        Agreements storage agreement = agreements[_agreementId];
        require(totalBitsPerBuyer[_agreementId][msg.sender] < agreement.price,"total payment made");
        require(agreement.saleEnded == false,"Agreement ended already");
        require(bitLevel != _bitLevel);
        require(block.timestamp >= agreement.agreementEndAt,"The agreement has not ended yet");
    //calculate buyer's penalty   
        uint bal = totalBitsPerBuyer[_agreementId][msg.sender];
        uint penaltyValue = (bal * 90) / 100;
    //Prevent re-entrancy attack    
        totalBitsPerBuyer[_agreementId][msg.sender] = 0;
    //Smart contract sends ether to the buyer
        IERC721(agreement.nftContractAddress).transferFrom(address(this),agreement.seller,penaltyValue );
        (bool sent, ) = payable(msg.sender).call{value:penaltyValue}("");
        require(sent, "Cannot send ether to the buyer"); 
        agreement.saleEnded == true;
        emit BuyerClaim(_nftTokenId,msg.sender); 
        emit AgreementEnded(_nftTokenId,msg.sender,agreement.saleEnded);
        return (success);
    }

    //A view function to get the values of Bits Enum for testing purpose
    function getBits() public view returns (Bits) {
    return bitLevel;
    }

    //A view function that returns  Bit-NFT-MarketPlace Commission
    function getBitMktCommision(uint _agreementId) internal view returns (uint) {
       Agreements storage  agreement = agreements[_agreementId];
        return (agreement.price * 5)/100;
    }
    //A view function that returns the fund receivable by an NFT seller
    function getSellersFundReceivable(uint _agreementId) internal view returns (uint) {
        Agreements storage agreement = agreements[_agreementId];
         return (agreement.price * 95)/100;
    }
    
}

