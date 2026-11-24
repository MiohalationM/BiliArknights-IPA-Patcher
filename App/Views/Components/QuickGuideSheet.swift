import SwiftUI

struct QuickGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Header summary banner
                    HStack(spacing: 14) {
                        RhodesEmblemIcon(size: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("四步上手玩 B 服")
                                .font(.headline)
                            Text("全程在手机本地离线完成，不上传文件，也不会改动原游戏包。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .appCard(cornerRadius: 18)

                    // Step-by-step walkthrough
                    VStack(alignment: .leading, spacing: 0) {
                        Text("使用步骤")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 18)
                            .padding(.top, 14)
                            .padding(.bottom, 10)

                        stepRow(
                            number: "1",
                            icon: "doc.zipper",
                            color: AppTheme.brandCyan,
                            title: "准备官服「砸壳 IPA」",
                            detail: "提前准备好《明日方舟》国服官方的已砸壳 .ipa 安装包（App Store 直接提取的加密包未砸壳，无法直接打补丁）。"
                        )
                        Divider().padding(.leading, 62)

                        stepRow(
                            number: "2",
                            icon: "sparkles",
                            color: .indigo,
                            title: "在首页选择并等待打包",
                            detail: "点击首页「选择砸壳 IPA」，工具会自动完成检查并打入 B 服登录补丁。2.8 GB 左右的安装包通常十几秒即可完成。"
                        )
                        Divider().padding(.leading, 62)

                        stepRow(
                            number: "3",
                            icon: "square.and.arrow.up",
                            color: .green,
                            title: "导出并用巨魔 / 自签安装",
                            detail: "打包完成后点击「导出 B 服 IPA」保存到「文件」，再用 TrollStore（巨魔商店）、AltStore、SideStore 或常用自签工具安装。"
                        )
                        Divider().padding(.leading, 62)

                        stepRow(
                            number: "4",
                            icon: "hand.tap.fill",
                            color: .orange,
                            title: "进游戏点右上角切换 B 服",
                            detail: "打开安装好的游戏，在启动界面点击右上角的渠道按钮，切换为「B服」后即可正常使用哔哩哔哩账号登录。"
                        )
                    }
                    .appCard(cornerRadius: 18)

                    // Common Questions
                    VStack(alignment: .leading, spacing: 0) {
                        Text("常见问题")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 18)
                            .padding(.top, 14)
                            .padding(.bottom, 10)

                        faqRow(
                            question: "提示「这个 IPA 还没砸壳」怎么办？",
                            answer: "说明当前文件仍带有苹果加密保护。本工具不负责砸壳，请从可信来源重新获取已砸壳的官服 IPA 后再导入。"
                        )
                        Divider().padding(.leading, 18)

                        faqRow(
                            question: "游戏后续更新版本了还能用吗？",
                            answer: "建议保持首页「游戏更新后自动适配」开启，更新后通常可直接自动适配；如果遇到大改版，也可以在「版本配置与高级工具」中直接导入新版 .json 配置文件，无需更新本工具。"
                        )
                        Divider().padding(.leading, 18)

                        faqRow(
                            question: "B 服安装包和官服可以同时装在手机上吗？",
                            answer: "取决于你使用的安装工具是否修改了应用包名（Bundle ID）。开启「B 服图标」后，即使共存也能在桌面一眼区分。"
                        )
                        Divider().padding(.leading, 18)

                        faqRow(
                            question: "为什么游戏内无法充值？",
                            answer: "为了防止误触官服苹果内购通道导致掉单，补丁版已禁用游戏内充值入口，如需充值请前往 B 站官方渠道或安卓端操作。"
                        )
                        Divider().padding(.leading, 18)

                        faqRow(
                            question: "打包完占用了 2~3 GB 空间怎么清理？",
                            answer: "导出并确认安装成功后，回到本工具点击「清理暂存文件」或首页的「删除缓存」，即可一键释放全部暂存空间，不会影响你已经导出的 IPA。"
                        )
                    }
                    .appCard(cornerRadius: 18)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(AppBackgroundView())
            .navigationTitle("使用指南")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("知道了") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func stepRow(
        number: String,
        icon: String,
        color: Color,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                IconBadge(systemName: icon, color: color, size: 36, iconScale: 0.46)
                Text(number)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(color))
                    .offset(x: 3, y: 3)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func faqRow(question: String, answer: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(question)
                .font(.subheadline.weight(.semibold))
            Text(answer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}
