//
//  MainView.swift
//  Factdustry
//
//  Created by Bright on 5/22/25.
//

import SwiftUI
import SwiftData

struct MainView: View {
    @State var isShowingCampaign = false
    @State var isShowingEditor = false
    @State var isShowingJoinGame = false
    @State var isShowingMods = false
    @State var isShowingSettings = false
    @State var isShowingCoreDatabase = false
    var buttonWidth: CGFloat = 150
    var body: some View {
        ZStack {
            if !isShowingCampaign, !isShowingEditor, !isShowingJoinGame, !isShowingMods, !isShowingSettings, !isShowingCoreDatabase {
                Image("Main_Screen_Bsckground")
                    .resizable()
                    .frame(width: 1032, height: 1032)
                    .ignoresSafeArea()
                
                VStack {
                    Text("Factdustry")
                        .font(.largeTitle)
                        .offset(y: -200)
                    
                    VStack {
                        HStack {
                            // campaign
                            ZStack {
                                Rectangle()
                                    .foregroundColor(Color(red: 0.5, green: 0.5, blue: 0.5))
                                    .frame(width: buttonWidth, height: 50)
                                    .overlay(
                                        Rectangle()
                                            .stroke(Color(white: 0.3), lineWidth: 5)
                                    )
                                
                                Text("Campaign")
                                    .foregroundColor(Color.black)
                            }
                            .onTapGesture {
                                isShowingCampaign = true
                            }
                            // editor
                            ZStack {
                                Rectangle()
                                    .foregroundColor(Color(red: 0.5, green: 0.5, blue: 0.5))
                                    .frame(width: buttonWidth, height: 50)
                                    .overlay(
                                        Rectangle()
                                            .stroke(Color(white: 0.3), lineWidth: 5)
                                    )
                                
                                Text("Editor")
                                    .foregroundColor(Color.black)
                            }
                            .onTapGesture {
                                isShowingEditor = true
                            }
                        }
                        HStack {
                            // join game
                            ZStack {
                                Rectangle()
                                    .foregroundColor(Color(red: 0.5, green: 0.5, blue: 0.5))
                                    .frame(width: buttonWidth, height: 50)
                                    .overlay(
                                        Rectangle()
                                            .stroke(Color(white: 0.3), lineWidth: 5)
                                    )
                                
                                Text("Join Game")
                                    .foregroundColor(Color.black)
                            }
                            .onTapGesture {
                                isShowingJoinGame = true
                            }
                            // mods
                            ZStack {
                                Rectangle()
                                    .foregroundColor(Color(red: 0.5, green: 0.5, blue: 0.5))
                                    .frame(width: buttonWidth, height: 50)
                                    .overlay(
                                        Rectangle()
                                            .stroke(Color(white: 0.3), lineWidth: 5)
                                    )
                                
                                Text("Mods")
                                    .foregroundColor(Color.black)
                            }
                            .onTapGesture {
                                isShowingMods = true
                            }
                        }
                        HStack {
                            // settings
                            ZStack {
                                Rectangle()
                                    .foregroundColor(Color(red: 0.5, green: 0.5, blue: 0.5))
                                    .frame(width: buttonWidth, height: 50)
                                    .overlay(
                                        Rectangle()
                                            .stroke(Color(white: 0.3), lineWidth: 5)
                                    )
                                
                                Text("Settings")
                                    .foregroundColor(Color.black)
                            }
                            .onTapGesture {
                                isShowingSettings = true
                            }
                            // core database
                            ZStack {
                                Rectangle()
                                    .foregroundColor(Color(red: 0.5, green: 0.5, blue: 0.5))
                                    .frame(width: buttonWidth, height: 50)
                                    .overlay(
                                        Rectangle()
                                            .stroke(Color(white: 0.3), lineWidth: 5)
                                    )
                                
                                Text("Core Database")
                                    .foregroundColor(Color.black)
                            }
                            .onTapGesture {
                                isShowingCoreDatabase = true
                            }
                        }
                    }
                }
            }
            
            if isShowingCampaign {
                MindustrySectorView(isShowingCampaign: $isShowingCampaign)
            }
            
            if isShowingEditor {
                MapEditorView()
            }
            
            if isShowingCoreDatabase {
                CoreDatabase()
            }
        }
    }
}

#Preview {
    MainView()
}
