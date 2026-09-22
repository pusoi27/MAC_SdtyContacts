import SwiftUI
import Contacts
import UniformTypeIdentifiers

/// App version sourced from the target's version settings
/// (MARKETING_VERSION and CURRENT_PROJECT_VERSION).
enum AppInfo {
    static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "v\(version) (\(build))"
    }
}

/// Wraps vCard text so it can be saved with a file exporter.
struct VCardDocument: FileDocument {
    nonisolated static let readableContentTypes: [UTType] = [.vCard]

    var text: String

    init(text: String = "") {
        self.text = text
    }

    nonisolated init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    nonisolated func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Create a contact from an appointment card screenshot:
/// pick an image, extract the contact with OCR, review it, then add it
/// directly to Contacts or export it as a .vcf file.
struct ContentView: View {
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var imageData: Data?
    @State private var selectedImageName = ""
    @State private var isExtracting = false
    @State private var isSavingToContacts = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    @State private var hasContact = false
    @State private var contactName = ""
    @State private var phoneNumber = ""
    @State private var email = ""
    @State private var notes = ""

    private var currentContact: PhoneContact {
        var contact = PhoneContact(
            childName: "",
            parentName: "",
            phoneNumber: phoneNumber.trimmingCharacters(in: .whitespaces),
            email: email.trimmingCharacters(in: .whitespaces),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        contact.setContactName(contactName)
        return contact
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Screenshot") {
                    if let imageData, let preview = platformImage(from: imageData) {
                        preview
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                            .frame(maxWidth: .infinity)
                    }

                    Button(selectedImageName.isEmpty ? "Choose Screenshot…" : selectedImageName) {
                        showImporter = true
                    }

                    Button {
                        extractContact()
                    } label: {
                        if isExtracting {
                            HStack {
                                ProgressView()
                                Text("Reading screenshot…")
                            }
                        } else {
                            Text("Extract Contact")
                        }
                    }
                    .disabled(imageData == nil || isExtracting)
                }

                if hasContact {
                    Section("Review Contact") {
                        TextField("Name", text: $contactName)
                        TextField("Phone Number", text: $phoneNumber)
                        TextField("Email", text: $email)
                        VStack(alignment: .leading) {
                            Text("Notes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $notes)
                                .frame(minHeight: 100)
                        }
                    }

                    Section {
                        Button {
                            addToContacts()
                        } label: {
                            if isSavingToContacts {
                                HStack {
                                    ProgressView()
                                    Text("Saving…")
                                }
                            } else {
                                Label("Add to Contacts", systemImage: "person.crop.circle.badge.plus")
                            }
                        }
                        .disabled(contactName.trimmingCharacters(in: .whitespaces).isEmpty || isSavingToContacts)

                        Button {
                            showExporter = true
                        } label: {
                            Label("Save VCF File…", systemImage: "square.and.arrow.down")
                        }
                        .disabled(contactName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if let successMessage {
                    Section {
                        Text(successMessage)
                            .foregroundStyle(.green)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                } footer: {
                    Text("Contact Extractor \(AppInfo.versionString)")
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
            .navigationTitle("Contact Extractor")
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.image]
            ) { result in
                handleImport(result)
            }
            .fileExporter(
                isPresented: $showExporter,
                document: VCardDocument(text: currentContact.vCard),
                contentType: .vCard,
                defaultFilename: currentContact.safeFilename
            ) { result in
                switch result {
                case .success(let url):
                    successMessage = "vCard saved: \(url.lastPathComponent)"
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        errorMessage = nil
        successMessage = nil
        switch result {
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            do {
                imageData = try Data(contentsOf: url)
                selectedImageName = url.lastPathComponent
                hasContact = false
            } catch {
                errorMessage = "Could not read image: \(error.localizedDescription)"
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func extractContact() {
        guard let imageData else { return }
        isExtracting = true
        errorMessage = nil
        successMessage = nil
        Task {
            do {
                let contact = try await ContactExtractor.extract(from: imageData)
                contactName = contact.contactName
                phoneNumber = contact.phoneNumber
                email = contact.email
                notes = contact.notes
                hasContact = true
            } catch {
                errorMessage = "Extraction failed: \(error.localizedDescription)"
            }
            isExtracting = false
        }
    }

    /// Saves the reviewed contact directly into the user's contacts.
    /// The note field is only included in the .vcf export, because writing
    /// contact notes requires a restricted Apple entitlement.
    private func addToContacts() {
        let contact = currentContact
        isSavingToContacts = true
        errorMessage = nil
        successMessage = nil
        Task {
            defer { isSavingToContacts = false }
            let store = CNContactStore()
            do {
                let granted = try await store.requestAccess(for: .contacts)
                guard granted else {
                    errorMessage = "Contacts access was denied. Enable it in Settings > Privacy > Contacts."
                    return
                }

                let newContact = CNMutableContact()
                newContact.contactType = .person
                // Keep the display format "child (parent)" as the given name,
                // matching the vCard's FN-only naming.
                newContact.givenName = contact.contactName
                if !contact.phoneNumber.isEmpty {
                    newContact.phoneNumbers = [
                        CNLabeledValue(
                            label: CNLabelPhoneNumberMobile,
                            value: CNPhoneNumber(stringValue: contact.phoneNumber)
                        )
                    ]
                }
                if !contact.email.isEmpty {
                    newContact.emailAddresses = [
                        CNLabeledValue(label: CNLabelHome, value: contact.email as NSString)
                    ]
                }

                let saveRequest = CNSaveRequest()
                saveRequest.add(newContact, toContainerWithIdentifier: nil)
                try store.execute(saveRequest)
                successMessage = "Added \"\(contact.contactName)\" to Contacts."
            } catch {
                errorMessage = "Could not save to Contacts: \(error.localizedDescription)"
            }
        }
    }

    private func platformImage(from data: Data) -> Image? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        return nil
        #endif
    }
}

#Preview {
    ContentView()
}
