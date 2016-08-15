//
//  ViewController.swift
//  MoyaDemo
//
//  Created by zm_iOS on 16/7/11.
//  Copyright © 2016年 zm_iOS. All rights reserved.
//

import UIKit
import Moya

enum ATarget: TargetType {
    case Base
    case Help(String)
}

extension ATarget {
    
    var baseURL: NSURL {
        return NSURL(string: "https://dribbble.com/")!
    }
    
    var path: String {
        switch self {
        case .Base:
            return ""
        case .Help(let topath):
            return topath
        }
    }
    
    var method: Moya.Method {
        return Moya.Method.GET
    }
    
    var parameters: [String : AnyObject]? {
        return nil
    }
    
    var sampleData: NSData {
        let data = "Im local data"
        return NSData(bytes: data, length: data.characters.count)
    }
    
    var multipartBody: [MultipartFormData]? {
        return nil
    }
}

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        
        let button = UIButton(frame: CGRectMake(100,100,100,100))
        button.setTitle("success", forState: .Normal)
        button.setTitleColor(UIColor.blackColor(), forState: .Normal)
        button.addTarget(self, action: #selector(buttonTapped), forControlEvents: .TouchUpInside)
        self.view.addSubview(button)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    func buttonTapped() {
        let provider = MoyaProvider<ATarget>(stubClosure: MoyaProvider.ImmediatelyStub)
        provider.request(.Base) {
            responce in
            switch responce {
            case .Success(let data):
                do {
                 try NSLog("\(data.mapString())")
                } catch _ {}
            case .Failure(let err):
                NSLog("\(err)")
            }
        }
        
        provider.request(.Help("designers")) {
            responce in
            switch responce {
            case .Success(let data):
                do {
                    try NSLog("\(data.mapString())")
                } catch _ {}
            case .Failure(let err):
                NSLog("\(err)")
            }
        }
    }

}

